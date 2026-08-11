defmodule CodeMySpec.Qa.QaAttempts do
  @moduledoc """
  Domain functions for QA attempt lifecycle.

  Each story accumulates an ordered log of QA attempts submitted by agents.
  The latest attempt with `status: :pass` and no associated invalidation
  satisfies the `qa_complete` requirement for the story.
  """

  import Ecto.Query, warn: false

  alias CodeMySpec.Qa.QaAttempt
  alias CodeMySpec.Repo
  alias CodeMySpec.Sessions.Session
  alias CodeMySpec.Users.Scope

  @doc """
  Submit a QA outcome for an active qa_complete task.

  Required params: `:task_id`, `:status`, `:scenarios`.
  Optional: `:issue_ids`.

  Resolves `story_id` and `agent_id` from the session owning the task.
  Sets `parent_attempt_id` to the most-recent prior attempt on the story.
  The parent-link lookup + insert run in a transaction so concurrent
  submits don't produce a diamond chain.

  Returns `{:ok, attempt}` or `{:error, changeset | atom}`.
  """
  @spec submit(Scope.t(), map()) ::
          {:ok, QaAttempt.t()} | {:error, Ecto.Changeset.t() | atom()}
  def submit(%Scope{} = scope, params) do
    task_id = Map.get(params, :task_id) || Map.get(params, "task_id")

    with :ok <- validate_findings_path(params) do
      Repo.transaction(fn ->
        with {:ok, {story_id, agent_id}} <- resolve_task_info(scope, task_id),
             parent_attempt_id <- find_latest_attempt_id(story_id),
             attrs <- build_attrs(params, story_id, agent_id, task_id, parent_attempt_id),
             {:ok, attempt} <- insert_attempt(attrs) do
          attempt
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  # A `fail` or `partial` outcome MUST be backed by issue ids. Agents
  # were filing findings into a result.md text blob that the harness
  # never read — every non-pass came back with `issue_ids: []` and the
  # finding disappeared. Refuse the submission so the agent has to call
  # `create_issue` first.
  defp validate_findings_path(params) do
    status = Map.get(params, :status) || Map.get(params, "status")
    issue_ids = Map.get(params, :issue_ids) || Map.get(params, "issue_ids") || []

    cond do
      status in [:pass, "pass"] ->
        :ok

      issue_ids != [] ->
        :ok

      true ->
        {:error, :fail_requires_issue_ids}
    end
  end

  defp build_attrs(params, story_id, agent_id, task_id, parent_attempt_id) do
    %{
      story_id: story_id,
      status: Map.get(params, :status) || Map.get(params, "status"),
      scenarios: Map.get(params, :scenarios) || Map.get(params, "scenarios") || [],
      issue_ids: Map.get(params, :issue_ids) || Map.get(params, "issue_ids") || [],
      agent_id: agent_id,
      task_id: task_id,
      parent_attempt_id: parent_attempt_id,
      submitted_at: DateTime.utc_now()
    }
  end

  defp insert_attempt(attrs) do
    %QaAttempt{}
    |> QaAttempt.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  List QA attempts for a story, most-recent first.

  Preloads `:invalidations`. Scoped to the active project via story association.

  Returns a list of `QaAttempt` structs.
  """
  @spec list(Scope.t(), integer()) :: [QaAttempt.t()]
  def list(%Scope{active_project: nil}, _story_id), do: []

  def list(%Scope{} = scope, story_id) do
    QaAttempt
    |> by_story(story_id)
    |> by_project(scope)
    |> order_by([a], desc: a.inserted_at, desc: a.id)
    |> preload(:invalidations)
    |> Repo.all()
  end

  @doc """
  List QA attempts across the project's stories.

  Options:

    * `:include_older` (default `false`) — when `false`, returns only
      the most-recent attempt per story (after invalidation filtering);
      when `true`, returns every attempt.
    * `:include_invalidated` (default `false`) — when `false`, filters
      out attempts that carry an invalidation event.

  Returns a list of `QaAttempt` structs with `:story` and
  `:invalidations` preloaded, ordered most-recent first.
  """
  @spec list_project(Scope.t(), keyword()) :: [QaAttempt.t()]
  def list_project(scope, opts \\ [])

  def list_project(%Scope{active_project: nil}, _opts), do: []

  def list_project(%Scope{} = scope, opts) do
    include_older = Keyword.get(opts, :include_older, false)
    include_invalidated = Keyword.get(opts, :include_invalidated, false)

    QaAttempt
    |> by_project(scope)
    |> order_by([a], desc: a.submitted_at, desc: a.id)
    |> preload([:story, :invalidations])
    |> Repo.all()
    |> maybe_drop_invalidated(include_invalidated)
    |> maybe_collapse_to_latest(include_older)
  end

  defp maybe_drop_invalidated(attempts, true), do: attempts

  defp maybe_drop_invalidated(attempts, false) do
    Enum.reject(attempts, fn a -> match?([_ | _], a.invalidations) end)
  end

  defp maybe_collapse_to_latest(attempts, true), do: attempts

  defp maybe_collapse_to_latest(attempts, false) do
    attempts
    |> Enum.group_by(& &1.story_id)
    |> Enum.map(fn {_story_id, group} ->
      Enum.max_by(group, & &1.submitted_at, DateTime)
    end)
    |> Enum.sort_by(& &1.submitted_at, {:desc, DateTime})
  end

  @doc """
  One attempt by id, only if it belongs to the scope's project.

  `nil` for an attempt that exists in another project, which is the same answer
  as one that does not exist — the caller has no business telling those apart.

  Lives here rather than in `Invalidations` because `by_project/2` does, and a
  second copy of the join is a second place for the fail-closed `active_project:
  nil` clause to be forgotten.
  """
  @spec get_in_project(Scope.t(), Ecto.UUID.t()) :: QaAttempt.t() | nil
  def get_in_project(%Scope{} = scope, attempt_id) do
    QaAttempt
    |> where([a], a.id == ^attempt_id)
    |> by_project(scope)
    |> Repo.one()
  end

  @doc """
  Is `qa_complete` satisfied for the story?

  True iff the **most-recent attempt on the story** (regardless of
  status) is `status: :pass` AND carries no invalidation. A later
  `:partial` / `:fail` submission overrides an earlier `:pass`; an
  invalidation on the latest pass also clears satisfaction.

  Returns `false` when the scope has no active project (fails closed
  to prevent cross-project reads).
  """
  @spec complete?(Scope.t(), integer()) :: boolean()
  def complete?(%Scope{active_project: nil}, _story_id), do: false

  def complete?(%Scope{} = scope, story_id) do
    latest =
      QaAttempt
      |> by_story(story_id)
      |> by_project(scope)
      |> order_by([a], desc: a.inserted_at, desc: a.id)
      |> limit(1)
      |> preload(:invalidations)
      |> Repo.one()

    passed?(latest)
  end

  @doc """
  Whether an attempt counts as a QA pass.

  A pass that was later invalidated is not one — re-QA is required, which is why
  `invalidations` must be empty as well as the status being `:pass`. Public so a
  caller holding a preloaded attempt (the requirement graph does) decides with
  this rather than re-stating the rule.
  """
  @spec passed?(QaAttempt.t() | nil) :: boolean()
  def passed?(%QaAttempt{status: :pass, invalidations: []}), do: true
  def passed?(_), do: false

  defp by_story(query, story_id) do
    where(query, [a], a.story_id == ^story_id)
  end

  # Fail-closed when no active project: returning a query that matches
  # nothing prevents cross-project leakage if a caller forgets to set
  # `active_project` on the scope.
  defp by_project(query, %Scope{active_project: nil}), do: where(query, [_], false)

  defp by_project(query, %Scope{active_project: project}) do
    join(query, :inner, [a], s in assoc(a, :story), on: s.project_id == ^project.id)
  end

  defp find_latest_attempt_id(story_id) do
    QaAttempt
    |> where([a], a.story_id == ^story_id)
    |> order_by([a], desc: a.inserted_at, desc: a.id)
    |> limit(1)
    |> select([a], a.id)
    |> Repo.one()
  end

  defp resolve_task_info(%Scope{active_project: nil}, _task_id),
    do: {:error, :no_active_project}

  defp resolve_task_info(%Scope{} = scope, task_id) when is_binary(task_id) do
    project_id = scope.active_project.id

    # `tasks` is `{:array, :map}` (PG `jsonb[]`), not a single `jsonb`,
    # so the `@>` operator doesn't apply. Select only the `tasks`
    # column so we skip Ecto's enum cast on `type` — stale sessions
    # in the DB with deprecated `type` values would otherwise crash
    # `Repo.all/1` here, even though we only care about `tasks`.
    task_arrays =
      Session
      |> where([s], s.project_id == ^project_id)
      |> select([s], s.tasks)
      |> Repo.all()

    case find_task(task_arrays, task_id) do
      nil -> {:error, :task_not_found}
      task -> {:ok, {task_field(task, :story_id), task_field(task, :agent_id)}}
    end
  end

  defp resolve_task_info(_scope, _task_id), do: {:error, :task_id_required}

  defp find_task(task_arrays, task_id) do
    task_arrays
    |> List.flatten()
    |> Enum.find(&task_matches?(&1, task_id))
  end

  defp task_matches?(%{id: id}, task_id), do: id == task_id
  defp task_matches?(%{"id" => id}, task_id), do: id == task_id
  defp task_matches?(_, _), do: false

  defp task_field(task, key) when is_map(task) do
    Map.get(task, key) || Map.get(task, Atom.to_string(key))
  end
end
