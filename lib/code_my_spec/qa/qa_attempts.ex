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

    case latest do
      %QaAttempt{status: :pass, invalidations: []} -> true
      _ -> false
    end
  end

  defp by_story(query, story_id) do
    where(query, [a], a.story_id == ^story_id)
  end

  # Fail-closed when no active project: returning a query that matches
  # nothing prevents cross-project leakage if a caller forgets to set
  # `active_project` on the scope.
  defp by_project(query, %Scope{active_project: nil}), do: where(query, [_], false)

  defp by_project(query, %Scope{active_project: project}) do
    join(query, :inner, [a], s in assoc(a, :story),
      on: s.project_id == ^project.id
    )
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
