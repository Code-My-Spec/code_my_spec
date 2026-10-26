defmodule CodeMySpec.Qa.QaAttempts do
  @moduledoc """
  Domain functions for QA attempt lifecycle.

  Each story accumulates an ordered log of QA attempts submitted by agents.
  Whether they satisfy `qa_complete` is `CodeMySpec.Qa.Verdict`'s call: the
  newest non-stale attempt must be a certified, uninvalidated pass.
  """

  import Ecto.Query, warn: false

  require Logger

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Issues
  alias CodeMySpec.Qa.QaAttempt
  alias CodeMySpec.Qa.StoryReviews
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.GraphInputs
  alias CodeMySpec.TaskOwner
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Utils.MapAccess

  @doc """
  Submit a QA outcome for an active qa_complete task.

  Required params: `:task_id`, `:status`, `:scenarios`.
  Optional: `:issue_ids`.

  Resolves `story_id` and `agent_id` from the agent owning the task.
  Sets `parent_attempt_id` to the most-recent prior attempt on the story.
  The parent-link lookup + insert run in a transaction so concurrent
  submits don't produce a diamond chain.

  Returns `{:ok, attempt}` or `{:error, changeset | atom}`.
  """
  @spec submit(Scope.t(), map()) ::
          {:ok, QaAttempt.t()} | {:error, Ecto.Changeset.t() | atom()}
  def submit(%Scope{} = scope, params) do
    task_id = MapAccess.get(params, :task_id)

    with :ok <- validate_findings_path(params) do
      Repo.transaction(fn -> record_attempt(scope, params, task_id) end)
      |> tap(&announce_graph_change(scope, &1))
      |> tap(&announce_story_passed(scope, &1))
    end
  end

  defp record_attempt(scope, params, task_id) do
    with {:ok, {story_id, agent_id, task}} <- resolve_task_info(scope, task_id),
         {:ok, review, current?} <- StoryReviews.fetch(scope, task, story_id),
         parent_attempt_id <- find_latest_attempt_id(story_id),
         attrs <- build_attrs(params, story_id, agent_id, task_id, parent_attempt_id),
         attrs <-
           Map.merge(attrs, %{
             reviewed_commit: review.commit,
             reviewed_submissions: review.submissions,
             review_started_at: review.started_at,
             review_certified_at: review.certified_at,
             stale: not current?
           }),
         {:ok, attempt} <- insert_attempt(attrs) do
      apply_review_findings(scope, attempt, review, current?)

      complete_review_task(scope, task_id, agent_id)
      attempt
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # A current pass, announced for Agents: a story whose work is already on main
  # finishes here rather than at a landing, and its team is free then
  # (`Agents.Events`). Qa sits below Promotion and Agents, so it says what
  # happened and does not decide what follows.
  defp announce_story_passed(scope, {:ok, %QaAttempt{status: :pass, stale: false} = attempt}) do
    :telemetry.execute([:code_my_spec, :qa, :story_passed], %{}, %{
      scope: scope,
      story_id: attempt.story_id
    })
  end

  defp announce_story_passed(_scope, _result), do: :ok

  # Historical reviews cannot attribute findings or return newer fixes.
  defp apply_review_findings(_scope, _attempt, _review, false), do: :ok

  defp apply_review_findings(scope, attempt, review, true) do
    Issues.attribute_to_story(scope, attempt.issue_ids || [], attempt.story_id)
    rework_reviewed_findings(scope, attempt, review)
  end

  defp rework_reviewed_findings(_scope, %{status: :pass}, _review), do: :ok

  defp rework_reviewed_findings(scope, attempt, review) do
    reviewed_ids = Enum.filter(attempt.issue_ids || [], &Map.has_key?(review.submissions, &1))

    case Issues.rework_story_submissions(
           scope,
           attempt.story_id,
           review.submissions,
           reviewed_ids,
           "Story QA #{attempt.id}: #{attempt.status}"
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # A read on the `Agents.Agent` leaf; Qa sits below Agents.
  defp agent_in_project(%Scope{active_project_id: project_id}, agent_id)
       when is_binary(project_id) and is_binary(agent_id) do
    case Ecto.UUID.cast(agent_id) do
      {:ok, id} -> Repo.get_by(Agent, id: id, project_id: project_id)
      :error -> nil
    end
  end

  defp agent_in_project(_scope, _agent_id), do: nil

  defp complete_review_task(scope, task_id, agent_id) do
    owner = agent_in_project(scope, agent_id) || task_owner(scope, task_id)

    case owner && TaskOwner.complete_task(scope, owner, task_id, :completed) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
      nil -> Repo.rollback(:qa_task_owner_not_found)
    end
  end

  # The agent holding the task, when the caller did not name its agent.
  defp task_owner(scope, task_id) do
    scope.active_project_id
    |> agent_tasks()
    |> Enum.find(fn {_id, tasks} -> find_task(List.wrap(tasks), task_id) end)
    |> case do
      {id, _tasks} -> Repo.get(Agent, id)
      nil -> nil
    end
  end

  # After commit and only on success: a recompute must not read a row that
  # might roll back. The story entities ride along so a consumer with no
  # handler for this kind still recomputes the story (a failed review can reset
  # submission nodes in the same transaction).
  defp announce_graph_change(scope, {:ok, _attempt} = result) do
    GraphInputs.event(
      scope,
      "Qa",
      "qa_attempt_submitted",
      %{},
      GraphInputs.story_entities(result),
      # An attempt is a statement about the story, not about the tree it was
      # run against.
      :project_wide
    )
  end

  defp announce_graph_change(_scope, _other), do: :ok

  # A `fail` or `partial` outcome must be backed by issue ids, so the agent
  # calls `create_issue` first; a finding with no issue is lost.
  defp validate_findings_path(params) do
    status = MapAccess.get(params, :status)
    issue_ids = MapAccess.get(params, :issue_ids, [])

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
      status: MapAccess.get(params, :status),
      scenarios: MapAccess.get(params, :scenarios, []),
      issue_ids: MapAccess.get(params, :issue_ids, []),
      agent_id: agent_id,
      task_id: task_id,
      tools_used: MapAccess.get(params, :tools_used),
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
  Record evidence uploaded for an already-inserted attempt.

  Status, scenarios and issue_ids are untouched. A second write because each
  file's S3 key is keyed by the attempt's own id (`CodeMySpec.Qa.EvidenceUpload`).
  On failure returns the original attempt rather than lose a recorded pass.
  """
  @spec attach_evidence(QaAttempt.t(), [map()]) :: QaAttempt.t()
  def attach_evidence(attempt, [] = _evidence), do: attempt

  def attach_evidence(attempt, evidence) do
    case attempt |> QaAttempt.changeset(%{evidence: evidence}) |> Repo.update() do
      {:ok, updated} -> updated
      {:error, _changeset} -> attempt
    end
  end

  @doc "Remove named evidence from an attempt and append an audit record without changing its verdict."
  def remove_evidence(scope, attempt_id, names, reason) do
    with true <- is_list(names) and names != [] and Enum.all?(names, &is_binary/1),
         true <- is_binary(reason) and String.trim(reason) != "",
         {:ok, _uuid} <- Ecto.UUID.cast(attempt_id) do
      Repo.transaction(fn ->
        attempt =
          QaAttempt
          |> where([a], a.id == ^attempt_id)
          |> by_project(scope)
          |> lock("FOR UPDATE")
          |> Repo.one()

        cond do
          is_nil(attempt) ->
            Repo.rollback(:attempt_not_found)

          Enum.any?(names, fn name -> not Enum.any?(attempt.evidence, &(&1.name == name)) end) ->
            Repo.rollback(:evidence_not_found)

          true ->
            {removed, kept} = Enum.split_with(attempt.evidence, &(&1.name in names))

            correction = %{
              "removed" => Enum.map(removed, & &1.name),
              "reason" => String.trim(reason),
              "by_user_id" => scope.user && scope.user.id,
              "at" => DateTime.utc_now() |> DateTime.to_iso8601()
            }

            attempt
            |> Ecto.Changeset.change(
              evidence_corrections: attempt.evidence_corrections ++ [correction]
            )
            |> Ecto.Changeset.put_embed(:evidence, kept)
            |> Repo.update!()
        end
      end)
    else
      false -> {:error, :invalid_correction}
      :error -> {:error, :attempt_not_found}
    end
  end

  @doc """
  List QA attempts for a story, most-recent first.

  Preloads `:invalidations`. Scoped to the active project via story association.

  Returns a list of `QaAttempt` structs.
  """
  @spec list(Scope.t(), integer()) :: [QaAttempt.t()]
  def list(%Scope{active_project_id: nil}, _story_id), do: []

  def list(%Scope{} = scope, story_id) do
    QaAttempt
    |> by_story(story_id)
    |> by_project(scope)
    |> order_by([a], desc: a.inserted_at, desc: a.id)
    |> preload([:invalidations])
    |> Repo.all()
  end

  @doc """
  One QA attempt by id, scoped to the active project via its story — for
  serving its evidence same-origin. `nil` if it does not exist or belongs
  to a different project.
  """
  @spec get(Scope.t(), Ecto.UUID.t()) :: QaAttempt.t() | nil
  def get(%Scope{active_project_id: nil}, _attempt_id), do: nil

  def get(%Scope{} = scope, attempt_id) do
    QaAttempt
    |> where([a], a.id == ^attempt_id)
    |> by_project(scope)
    |> Repo.one()
  rescue
    Ecto.Query.CastError -> nil
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

  def list_project(%Scope{active_project_id: nil}, _opts), do: []

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

  `nil` for an attempt in another project, the same answer as one that does
  not exist.
  """
  @spec get_in_project(Scope.t(), Ecto.UUID.t()) :: QaAttempt.t() | nil
  def get_in_project(%Scope{} = scope, attempt_id) do
    QaAttempt
    |> where([a], a.id == ^attempt_id)
    |> by_project(scope)
    |> Repo.one()
  end

  @doc "Whether the story's newest attempt is an uninvalidated pass; see `Qa.Verdict.complete?/2`."
  defdelegate complete?(scope, story_id), to: CodeMySpec.Qa.Verdict

  @doc "Whether an attempt counts as a QA pass; see `Qa.Verdict.passed?/1`."
  defdelegate passed?(attempt), to: CodeMySpec.Qa.Verdict

  defp by_story(query, story_id) do
    where(query, [a], a.story_id == ^story_id)
  end

  # Fail-closed with no active project. Keyed on `active_project_id`, not the
  # loaded association, which many scopes do not carry.
  defp by_project(query, %Scope{active_project_id: nil}), do: where(query, [_], false)

  defp by_project(query, %Scope{active_project_id: project_id}) do
    join(query, :inner, [a], s in assoc(a, :story), on: s.project_id == ^project_id)
  end

  defp find_latest_attempt_id(story_id) do
    QaAttempt
    |> where([a], a.story_id == ^story_id)
    |> order_by([a], desc: a.inserted_at, desc: a.id)
    |> limit(1)
    |> select([a], a.id)
    |> Repo.one()
  end

  defp resolve_task_info(%Scope{active_project_id: nil}, _task_id),
    do: {:error, :no_active_project}

  defp resolve_task_info(%Scope{} = scope, task_id) when is_binary(task_id) do
    project_id = scope.active_project_id

    # `tasks` is PG `jsonb[]`, so `@>` does not apply. Only `tasks` is selected,
    # skipping Ecto's enum cast on `type`, which crashes on deprecated values.
    agents = agent_tasks(project_id)

    case find_task(Enum.map(agents, &elem(&1, 1)), task_id) do
      nil ->
        {:error, {:task_not_found, open_qa_tasks(Enum.map(agents, &elem(&1, 1)))}}

      task ->
        cond do
          issue_id = task_field(task, :issue_id) ->
            {:error, {:issue_task_requires_issue_submission, issue_id}}

          story_id = task_field(task, :story_id) ->
            {:ok, {story_id, owner_of(task, task_id, agents), task}}

          true ->
            {:error, :task_has_no_story}
        end
    end
  end

  defp resolve_task_info(_scope, _task_id), do: {:error, :task_id_required}

  # Every task is an agent's; the task id is unique and is all this is given.
  defp agent_tasks(project_id) do
    Agent
    |> where([a], a.project_id == ^project_id)
    |> select([a], {a.id, a.tasks})
    |> Repo.all()
  end

  # Who did this QA: the agent row the task was found on (a task does not name
  # its agent).
  defp owner_of(task, task_id, agents) do
    case Enum.find(agents, fn {_id, tasks} -> find_task(List.wrap(tasks), task_id) end) do
      {agent_id, _tasks} -> agent_id
      nil -> task_field(task, :agent_id)
    end
  end

  # The open QA tasks with their stories, so a `task_not_found` refusal shows
  # which id goes where (a story id is the obvious wrong guess).
  defp open_qa_tasks(task_arrays) do
    task_arrays
    |> List.flatten()
    |> Enum.filter(fn task ->
      task_field(task, :status) in ["active", :active] and
        task_field(task, :requirement_name) == "qa_complete"
    end)
    |> Enum.map(&{task_field(&1, :id), task_field(&1, :story_id)})
    |> Enum.reject(fn {id, _story} -> is_nil(id) end)
  end

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
