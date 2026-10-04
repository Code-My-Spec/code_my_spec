defmodule CodeMySpec.Qa.QaAttempts do
  @moduledoc """
  Domain functions for QA attempt lifecycle.

  Each story accumulates an ordered log of QA attempts submitted by agents.
  The latest attempt with `status: :pass` and no associated invalidation
  satisfies the `qa_complete` requirement for the story.
  """

  import Ecto.Query, warn: false

  require Logger

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Configurations
  alias CodeMySpec.Issues
  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Qa.QaAttempt
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.GraphInputs
  alias CodeMySpec.Sessions.Session
  alias CodeMySpec.TaskOwner
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Utils.MapAccess

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
    task_id = MapAccess.get(params, :task_id)

    with :ok <- validate_findings_path(params) do
      Repo.transaction(fn ->
        with {:ok, {story_id, agent_id}} <- resolve_task_info(scope, task_id),
             parent_attempt_id <- find_latest_attempt_id(story_id),
             attrs <- build_attrs(params, story_id, agent_id, task_id, parent_attempt_id),
             {:ok, attempt} <- insert_attempt(attrs) do
          # The submission is the moment attribution is knowable: the agent has
          # just declared that these issues are the findings of a pass over
          # this story. `story_issues_resolved` gates the story's release on
          # them, and asking the agent to remember `story_id` on every
          # `create_issue` call did not work — every accepted issue on this
          # project reached triage with none. Only `:app` findings are
          # attributed; see `Issues.attribute_to_story/3`.
          Issues.attribute_to_story(scope, attempt.issue_ids || [], story_id)
          wait_on_filed_issues(scope, attempt, agent_id)
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> tap(&announce_graph_change(scope, &1))
    end
  end

  # An attempt that did not pass and named issues is waiting on those issues.
  #
  # Without this the story is handed straight back. `qa_complete` stays
  # unsatisfied and actionable, so the graph re-offers the same story against
  # the same code the moment QA finishes failing it — and QA, correctly, says
  # "this needs a coding fix, not another QA pass". The only way it had to say
  # so was a tap-out, which is a human gate.
  #
  # Measured on story 1053, 2026-09-22: three rounds of QA finding a real
  # regression, filing it, tapping out, a human denying the tap-out once coding
  # had landed the fix. Every technical step either side was autonomous and
  # correct; the three denials were mechanical.
  #
  # Blocking on the issue lets the system make the handoff itself — resolving it
  # releases the block and offers QA a turn (`TaskOwner.blocker_resolved/4`).
  #
  # Here rather than in the tool, because this is where `story_id` and
  # `agent_id` are already resolved and where attribution already happens; the
  # tool layer would have to look the owner up again to do the same thing.
  #
  # The obvious alternative does not exist: `qa_complete` (id 4) cannot take
  # `story_issues_resolved` (id 6) as a prerequisite, because 6 already depends
  # on 4 and the graph would cycle.
  #
  # Only on an open issue at or above the project's `fix_issues_min_severity`.
  # Nothing offers a fix below it (`story_issues_resolved` counts only what is
  # at it), so a block there never releases: QA e62dbe27 parked stories 36 and
  # 42 on two lows and the copy stopped. Such an issue stays recorded; the task
  # stays active and the attempt's `wait` says why, for the tool to tell QA.
  defp wait_on_filed_issues(_scope, %{status: :pass} = attempt, _agent_id), do: attempt

  defp wait_on_filed_issues(
         scope,
         %{issue_ids: [_ | _] = ids, task_id: task_id} = attempt,
         agent_id
       )
       when is_binary(task_id) and is_binary(agent_id) do
    threshold = Configurations.fix_issues_min_severity(scope)
    issues = ids |> Enum.map(&Issues.get_issue(scope, &1)) |> Enum.reject(&is_nil/1)

    case Enum.find(issues, &Issue.blocking?(&1, threshold)) do
      nil -> %{attempt | wait: {:not_blocking, threshold, issues}}
      issue -> %{attempt | wait: block_on(scope, attempt, agent_id, issue)}
    end
  end

  defp wait_on_filed_issues(_scope, attempt, _agent_id), do: attempt

  defp block_on(scope, attempt, agent_id, issue) do
    with {:ok, agent} <- Agents.fetch_agent(scope, agent_id),
         {:ok, _} <-
           TaskOwner.block_task(scope, agent, attempt.task_id, :issue, issue.id,
             reason: "waiting on issue #{issue.id}"
           ) do
      {:issue, issue.id}
    else
      _ -> nil
    end
  end

  # A submitted attempt is what `qa_complete` is computed from, so the graph
  # moved — and a pass is the case that matters most, because it unblocks
  # whatever was waiting behind the story.
  #
  # After the transaction commits, not inside it: `GraphWatcher` recomputes on
  # this, and a recompute that read the attempt before it committed would decide
  # from a row that might roll back. Only on success for the same reason.
  # An event rather than a mark, because there is nothing to ask: a submitted
  # attempt *is* what `qa_complete` reads, and `Requirements.Handlers` settles
  # that requirement across every story from the newest attempt each one has.
  # The entities ride along so a consumer with no handler for this kind still
  # falls back to recomputing the story.
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

  # A `fail` or `partial` outcome MUST be backed by issue ids. Agents
  # were filing findings into a result.md text blob that the harness
  # never read — every non-pass came back with `issue_ids: []` and the
  # finding disappeared. Refuse the submission so the agent has to call
  # `create_issue` first.
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

  Not a change to the claim the attempt already made — status, scenarios
  and issue_ids are untouched — but filling in evidence does take a second
  write, because the S3 key each file lands at is keyed by the attempt's
  own id (`CodeMySpec.Qa.EvidenceUpload`), which does not exist until the
  first write returns it. On any failure (vanishingly unlikely — the
  shape is built from known-good data, not user input) this returns the
  original attempt rather than lose a recorded pass over an evidence
  write.
  """
  @spec attach_evidence(QaAttempt.t(), [map()]) :: QaAttempt.t()
  def attach_evidence(attempt, [] = _evidence), do: attempt

  def attach_evidence(attempt, evidence) do
    case attempt |> QaAttempt.changeset(%{evidence: evidence}) |> Repo.update() do
      {:ok, updated} -> updated
      {:error, _changeset} -> attempt
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
    |> preload(:invalidations)
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

  @doc "Whether the story's newest attempt is an uninvalidated pass; see `Qa.Verdict.complete?/2`."
  defdelegate complete?(scope, story_id), to: CodeMySpec.Qa.Verdict

  @doc "Whether an attempt counts as a QA pass; see `Qa.Verdict.passed?/1`."
  defdelegate passed?(attempt), to: CodeMySpec.Qa.Verdict

  defp by_story(query, story_id) do
    where(query, [a], a.story_id == ^story_id)
  end

  # Fail-closed when no active project: returning a query that matches
  # nothing prevents cross-project leakage if a caller forgets to set
  # `active_project` on the scope.
  # Keyed on the id, not the loaded struct.
  #
  # It guarded on `active_project` and answered "no attempts exist" for any
  # scope that carried the id without the association loaded — which is every
  # scope `PortableHost` builds for the local endpoint. `qa_complete` then
  # reported "No valid QA pass attempt in DB" for a story whose passing attempt
  # was sitting in the table, and criterion 6491 is what caught it.
  #
  # Same shape as the `Stories.broadcast/2` guard fixed alongside it: a
  # presence check written against the struct while the body only ever needs the
  # id, so an unloaded association reads as an absence rather than as "not
  # asked for".
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
    project_id = scope.active_project.id

    # `tasks` is `{:array, :map}` (PG `jsonb[]`), not a single `jsonb`,
    # so the `@>` operator doesn't apply. Select only the `tasks`
    # column so we skip Ecto's enum cast on `type` — stale sessions
    # in the DB with deprecated `type` values would otherwise crash
    # `Repo.all/1` here, even though we only care about `tasks`.
    sessions = session_tasks(project_id)
    agents = agent_tasks(project_id)

    case find_task(sessions ++ Enum.map(agents, &elem(&1, 1)), task_id) do
      nil ->
        {:error, {:task_not_found, open_qa_tasks(sessions ++ Enum.map(agents, &elem(&1, 1)))}}

      task ->
        {:ok, {task_field(task, :story_id), owner_of(task, task_id, agents)}}
    end
  end

  defp resolve_task_info(_scope, _task_id), do: {:error, :task_id_required}

  defp session_tasks(project_id) do
    Session
    |> where([s], s.project_id == ^project_id)
    |> select([s], s.tasks)
    |> Repo.all()
  end

  # An agent we run holds its own tasks, and this looked only at sessions.
  #
  # So a QA agent under Alloy submitted its result against a real task id and
  # got `task_not_found` — the honest answer to the wrong question. Watched on
  # the war-epic copy, 2026-09-06: "QA is blocked: the required result
  # submission returns `task_not_found` because this conversation has no
  # registered session." The agent's own diagnosis was right, and the remedy it
  # inferred — register a session — is not one it can perform, so it stopped,
  # was nudged about the still-open `qa_complete`, and repeated for an hour.
  #
  # Both are searched rather than one chosen from the caller, because the task
  # id is the only thing this is given and it is unique across both. Choosing
  # would mean guessing which kind of caller sent it, and guessing wrong is the
  # failure being fixed.
  #
  # Same `{:array, :map}` note as sessions: `tasks` is PG `jsonb[]`, not a
  # single `jsonb`, so `@>` does not apply and the column is selected on its own
  # to skip Ecto's cast of columns this does not care about.
  defp agent_tasks(project_id) do
    Agent
    |> where([a], a.project_id == ^project_id)
    |> select([a], {a.id, a.tasks})
    |> Repo.all()
  end

  # Who did this QA.
  #
  # `task.agent_id` is set by `TaskOwner.activate_task/4`'s *session* clause and
  # not by its agent one — an agent-owned task does not name an agent, because
  # the row it lives on already is one. So an attempt from an agent recorded
  # `agent_id: nil`, and two real QA passes on story 1000 landed this morning
  # attributed to nobody.
  #
  # Read off the row the task was found on, which is the only place that knows.
  # A session-owned task keeps whatever the field says, which is where it is
  # written.
  defp owner_of(task, task_id, agents) do
    case Enum.find(agents, fn {_id, tasks} -> find_task(List.wrap(tasks), task_id) end) do
      {agent_id, _tasks} -> agent_id
      nil -> task_field(task, :agent_id)
    end
  end

  # The QA tasks that are actually open, so a refusal can name them.
  #
  # The war-epic QA agent submitted `task_id: "1000"` — story 1000's id, not its
  # task's — got `task_not_found`, and concluded its session was unregistered.
  # It was not: the id was simply the wrong one, and nothing in the refusal said
  # which id it wanted. It had been told, in the nudge two lines above
  # (`evaluate_task task_id: "e060369a-…"`), and used the number it had been
  # thinking about all turn instead.
  #
  # A story id is the obvious wrong guess here — every other QA surface is keyed
  # by story — so the refusal names the open QA task and its story together, and
  # the agent can see which number goes where.
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
