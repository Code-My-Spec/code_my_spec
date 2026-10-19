defmodule CodeMySpec.Sessions do
  @moduledoc """
  DB-backed session management.

  One session per Claude conversation. Tasks are tracked as embedded
  records within the session. The Sessions context is the public API
  boundary for all session and task operations.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Agents.Agent,
      CodeMySpec.Repo,
      CodeMySpec.Users.Scope,
      CodeMySpec.Utils
    ],
    exports: :all

  import Ecto.Query, warn: false
  require Logger

  alias CodeMySpec.Repo
  alias CodeMySpec.Sessions.Session
  alias CodeMySpec.Sessions.SessionType
  alias CodeMySpec.Agents.Agent.Task
  alias CodeMySpec.Users.Scope

  # A session reads as "active" if it was touched within this window: nothing
  # flips a session's status back when it ends, so recency is what keeps
  # "active" meaning "right now". One constant for every reader.
  @active_window_seconds 300

  @doc "The recency window (seconds) a session must be touched within to read as active."
  @spec active_window_seconds() :: pos_integer()
  def active_window_seconds, do: @active_window_seconds

  # ============================================================================
  # PubSub — session/task lifecycle broadcasts
  # ============================================================================

  @doc """
  Subscribe the caller to session-change broadcasts for the scope's
  active project. The agent progress view re-renders live off these.
  """
  @spec subscribe_sessions(Scope.t()) :: :ok | {:error, term()}
  def subscribe_sessions(%Scope{active_project_id: project_id}) when is_binary(project_id) do
    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, sessions_topic(project_id))
  end

  def subscribe_sessions(_scope), do: :ok

  defp sessions_topic(project_id), do: "project:#{project_id}:sessions"

  defp broadcast_change({:ok, %Session{project_id: project_id} = session} = result)
       when is_binary(project_id) do
    Phoenix.PubSub.broadcast(
      CodeMySpec.PubSub,
      sessions_topic(project_id),
      {:session_changed, session}
    )

    result
  end

  defp broadcast_change(result), do: result

  @doc """
  Mark a session as just-active by bumping its `updated_at`, then
  broadcasting the change. Called from the PostToolUse hook on every tool
  call so the agent-progress view can derive "active" by simple recency
  (updated within a few minutes) on load, while open pages refresh live.
  """
  @spec touch_session(Scope.t(), Session.t()) :: :ok
  def touch_session(%Scope{}, %Session{} = session) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(s in Session, where: s.id == ^session.id)
    |> Repo.update_all(set: [updated_at: now])

    broadcast_change({:ok, %Session{session | updated_at: now}})
    :ok
  end

  # ============================================================================
  # Session CRUD
  # ============================================================================

  @doc "Create a new session scoped to the user's project."
  def create_session(%Scope{} = scope, attrs) do
    %Session{}
    |> Session.scoped_changeset(attrs, scope)
    |> Repo.insert()
    |> broadcast_change()
  end

  @doc "Get a session by ID, scoped to project."
  def get_session(%Scope{} = scope, id) do
    Session
    |> where([s], s.id == ^id and s.project_id == ^scope.active_project_id)
    |> Repo.one()
    |> maybe_prune_orphan_tasks()
  end

  @doc "List all sessions for the project."
  def list_sessions(%Scope{} = scope) do
    Session
    |> where([s], s.project_id == ^scope.active_project_id)
    |> order_by([s], desc: s.inserted_at)
    |> Repo.all()
    |> Enum.map(&maybe_prune_orphan_tasks/1)
  end

  @doc "List active sessions for the project."
  def list_active_sessions(%Scope{} = scope) do
    Session
    |> where([s], s.project_id == ^scope.active_project_id and s.status == :active)
    |> order_by([s], desc: s.inserted_at)
    |> Repo.all()
    |> Enum.map(&maybe_prune_orphan_tasks/1)
  end

  # credo:disable-for-next-line ExSlop.Check.Readability.NarratorDoc
  @doc """
  The open task an agent is holding, wherever it lives.

  For a sub-agent assigned a task on an orchestrator's session (the task's
  `agent_id`): looked up by agent across the project's active sessions. `nil`
  when it holds nothing.
  """
  @spec open_task_for_agent(Scope.t(), String.t()) :: Task.t() | nil
  def open_task_for_agent(%Scope{} = scope, agent_id) when is_binary(agent_id) do
    scope
    |> list_active_sessions()
    |> Enum.find_value(fn session ->
      case Session.find_task_by_agent(session, agent_id) do
        %Task{status: status} = task when status not in [:completed, :cancelled] -> task
        _ -> nil
      end
    end)
  end

  def open_task_for_agent(_scope, _agent_id), do: nil

  @doc """
  When a registered sub-agent was last heard from, across the project's
  active sessions.

  `:not_registered` when no active session has a registration for this
  `agent_id` -- distinct from `{:ok, nil}`, a registration that has never
  sent a heartbeat. A caller deciding whether a sub-agent's claim on a task
  is stale (733ac788) needs to tell those two apart from "it answered
  recently": one says the agent is gone, the other says it has not yet had
  the chance to be touched.
  """
  @spec subagent_heartbeat(Scope.t(), String.t()) ::
          {:ok, DateTime.t() | nil} | :not_registered
  def subagent_heartbeat(%Scope{} = scope, agent_id) when is_binary(agent_id) do
    scope
    |> list_active_sessions()
    |> Enum.find_value(:not_registered, fn session ->
      case Enum.find(session.subagents || [], &(&1.agent_id == agent_id)) do
        nil -> nil
        subagent -> {:ok, subagent.last_heartbeat_at}
      end
    end)
  end

  def subagent_heartbeat(_scope, _agent_id), do: :not_registered

  @doc """
  Every task an agent is actively working, across the project's active
  sessions.

  Every match, unlike `open_task_for_agent/2`; `:active` only (a `:prepared`
  task is queued, not underway).
  """
  @spec list_active_tasks_for_agent(Scope.t(), String.t()) :: [Task.t()]
  def list_active_tasks_for_agent(%Scope{} = scope, agent_id) when is_binary(agent_id) do
    scope
    |> list_active_sessions()
    |> Enum.flat_map(fn session ->
      Enum.filter(session.tasks || [], &(&1.agent_id == agent_id and &1.status == :active))
    end)
  end

  def list_active_tasks_for_agent(_scope, _agent_id), do: []

  @doc """
  Every task ever opened against a story, across every session, finished or
  not.

  For the agent performance page's stage times, read from each task's own
  timestamps across every session the story passed through.
  """
  # Component-scoped tasks carry no story_id, so `component_id` matches too —
  # but only for tasks with no story_id of their own, or a shared component
  # pulls sibling stories' tasks into this story's cycle time.
  @spec list_tasks_for_story(Scope.t(), integer(), Ecto.UUID.t() | nil) :: [map()]
  def list_tasks_for_story(%Scope{} = scope, story_id, component_id \\ nil)
      when is_integer(story_id) do
    scope
    |> list_sessions()
    |> Enum.flat_map(fn session ->
      session.tasks
      |> List.wrap()
      |> Enum.filter(&own_or_unattributed?(&1, story_id, component_id))
      |> Enum.map(&Map.from_struct/1)
    end)
  end

  defp own_or_unattributed?(task, story_id, component_id) do
    task.story_id == story_id or
      (is_nil(task.story_id) and not is_nil(component_id) and task.component_id == component_id)
  end

  @doc "Find an active session by external conversation ID (Claude session ID)."
  def get_by_external_id(%Scope{} = scope, external_id) when is_binary(external_id) do
    Session
    |> where(
      [s],
      s.external_conversation_id == ^external_id and
        s.project_id == ^scope.active_project_id and
        s.status == :active
    )
    |> order_by([s], desc: s.inserted_at)
    |> limit(1)
    |> Repo.one()
    |> maybe_prune_orphan_tasks()
  end

  # Self-heal: tasks whose `session_type` names a renamed or removed agent task
  # module are stripped and the pruned list persisted.
  defp maybe_prune_orphan_tasks(nil), do: nil

  defp maybe_prune_orphan_tasks(%Session{tasks: tasks} = session) when is_list(tasks) do
    {valid, orphans} =
      Enum.split_with(tasks, fn t ->
        SessionType.valid_type?(t.session_type)
      end)

    if orphans == [] do
      session
    else
      Logger.info(
        "[Sessions] pruning #{length(orphans)} orphan task(s) from session #{session.id}: #{orphan_summary(orphans)}"
      )

      persist_pruned_tasks(session, valid)
    end
  end

  defp maybe_prune_orphan_tasks(session), do: session

  defp orphan_summary(orphans) do
    orphans
    |> Enum.map_join(", ", fn t -> "#{t.id}=#{inspect(t.session_type)}" end)
  end

  defp persist_pruned_tasks(%Session{} = session, valid_tasks) do
    session
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_embed(:tasks, valid_tasks)
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        updated

      {:error, changeset} ->
        Logger.warning(
          "[Sessions] orphan-task prune failed for session #{session.id}: #{inspect(changeset.errors)} — returning in-memory pruned struct"
        )

        %Session{session | tasks: valid_tasks}
    end
  end

  @doc "Update a session."
  def update_session(%Scope{} = _scope, %Session{} = session, attrs) do
    session
    |> Session.changeset(attrs)
    |> Repo.update()
    |> broadcast_change()
  end

  @doc """
  Register (or refresh) a sub-agent on a session.

  Idempotent on `agent_id`: calling twice for the same id refreshes
  `last_heartbeat_at` rather than appending.
  """
  @spec register_subagent(Scope.t(), Session.t(), map()) ::
          {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def register_subagent(%Scope{} = _scope, %Session{} = session, attrs) do
    session
    |> Session.register_subagent(attrs)
    |> Repo.update()
  end

  @doc """
  Refresh a registered sub-agent's heartbeat. No-op if it is not registered.
  """
  @spec touch_subagent(Scope.t(), Session.t(), String.t()) ::
          {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def touch_subagent(%Scope{} = _scope, %Session{} = session, agent_id) do
    session
    |> Session.touch_subagent(agent_id)
    |> Repo.update()
  end

  @doc """
  Unregister a sub-agent by `agent_id`.

  Removes the registration from the session's embedded `subagents` list.
  No-op if the agent was not registered.
  """
  @spec unregister_subagent(Scope.t(), Session.t(), String.t()) ::
          {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def unregister_subagent(%Scope{} = _scope, %Session{} = session, agent_id) do
    session
    |> Session.unregister_subagent(agent_id)
    |> Repo.update()
  end

  @doc "Delete a session (by struct or by ID string)."
  def delete_session(%Scope{} = _scope, %Session{} = session) do
    Repo.delete(session)
  end

  def delete_session(%Scope{} = scope, id) when is_binary(id) do
    case get_session(scope, id) do
      nil -> {:error, :not_found}
      session -> Repo.delete(session)
    end
  end

  # ============================================================================
  # Task lifecycle (operates on embedded tasks)
  # ============================================================================

  @doc """
  Create a draft task on a session (status: :prepared).

  Called by next-task to record what the agent should work on.
  Returns `{:ok, updated_session}` or `{:error, changeset}`.
  """
  def prepare_task(%Scope{} = _scope, %Session{} = session, task_attrs) do
    requirement_name = Map.get(task_attrs, :requirement_name)

    # Don't create duplicates — return existing if there's already a
    # prepared or active task for this requirement
    existing =
      (session.tasks || [])
      |> Enum.find(fn t ->
        t.requirement_name == requirement_name and t.status in [:prepared, :active]
      end)

    if existing do
      {:ok, session}
    else
      attrs =
        task_attrs
        |> Map.put_new(:id, Ecto.UUID.generate())
        |> Map.put(:status, :prepared)

      session
      |> Session.add_task(attrs)
      |> Repo.update()
      |> broadcast_change()
    end
  end

  @doc """
  Activate a prepared task (status: :prepared → :active).

  Called by start-task when the agent commits to working on it.
  Returns `{:ok, updated_session}` or `{:error, changeset}`.
  """
  def activate_task(%Scope{} = _scope, %Session{} = session, task_id, agent_id \\ nil) do
    # Microsecond precision so started_at lands strictly past any file
    # mtime that was synced earlier in the same request — Validation's
    # changed_since check can short-circuit deterministically without
    # a sleep crossing a second boundary.
    now = DateTime.utc_now()

    updates =
      %{status: :active, started_at: now}
      |> then(fn m -> if agent_id, do: Map.put(m, :agent_id, agent_id), else: m end)

    session
    |> Session.update_task(task_id, updates)
    |> Repo.update()
    |> broadcast_change()
  end

  @doc """
  Complete a task (mark as :completed or :failed).

  Returns `{:ok, updated_session}` or `{:error, changeset}`.
  """
  def complete_task(%Scope{} = _scope, %Session{} = session, task_id, result \\ :completed)
      when result in [:completed, :failed, :cancelled] do
    now = DateTime.utc_now()

    session
    |> Session.update_task(task_id, %{status: result, completed_at: now})
    |> Repo.update()
    |> broadcast_change()
  end

  @doc "Assign an agent_id to an active task."
  def assign_agent(%Scope{} = _scope, %Session{} = session, task_id, agent_id) do
    session
    |> Session.update_task(task_id, %{agent_id: agent_id})
    |> Repo.update()
  end

  @doc """
  Record an `{:ok, :invalid, feedback}` result on the session.

  Hashes `feedback` and compares against `session.last_eval_feedback_hash`:
  a match increments `eval_feedback_count`; a miss resets the count to 1
  and stores the new hash. The stop hook reads the count to detect a stuck
  loop.
  """
  @spec record_eval_feedback(Scope.t(), Session.t(), String.t()) ::
          {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def record_eval_feedback(%Scope{} = _scope, %Session{} = session, feedback)
      when is_binary(feedback) do
    hash = :crypto.hash(:sha256, feedback) |> Base.encode16(case: :lower)

    next_count =
      if session.last_eval_feedback_hash == hash,
        do: (session.eval_feedback_count || 0) + 1,
        else: 1

    session
    |> Session.changeset(%{
      last_eval_feedback_hash: hash,
      eval_feedback_count: next_count
    })
    |> Repo.update()
  end

  @doc """
  Clear the stuck-detection state on a passing evaluation.

  Called from the `{:ok, :valid}` paths so the next failure starts a fresh
  streak.
  """
  @spec clear_eval_feedback(Scope.t(), Session.t()) ::
          {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def clear_eval_feedback(%Scope{} = _scope, %Session{} = session) do
    session
    |> Session.changeset(%{
      last_eval_feedback_hash: nil,
      eval_feedback_count: 0
    })
    |> Repo.update()
  end

  @doc """
  Record that this session ran a Bash command able to move `HEAD` or rewrite
  the worktree without going through Write/Edit — a rebase, pull, merge,
  checkout, reset, cherry-pick, or stash pop/apply.

  `Validation` reads this when narrowing dirty files to the session's own
  writes: after a rewrite since the task started, unattributed dirty files
  may be inherited history (a rebase), not this session's work.

  Fire-and-forget, same as the rest of PostToolUse's bookkeeping — a tool
  call must proceed even when recording this fails.
  """
  @spec record_git_rewrite(Scope.t(), Session.t()) ::
          {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def record_git_rewrite(%Scope{} = _scope, %Session{} = session) do
    session
    |> Session.changeset(%{git_rewrite_at: DateTime.utc_now()})
    |> Repo.update()
  end

  @doc """
  Atomically reassign a sub-agent: clear `agent_id` from any task that
  currently carries it (other than `target_task_id`) and set
  `agent_id` on the target task — in a single `Repo.update`.

  Used by `assign_subagent`, so a partial failure cannot leave the sub-agent
  off its old task without landing on the new one.
  """
  @spec reassign_agent(Scope.t(), Session.t(), String.t(), String.t()) ::
          {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def reassign_agent(%Scope{} = _scope, %Session{} = session, target_task_id, agent_id) do
    new_tasks =
      Enum.map(session.tasks || [], fn task ->
        cond do
          task.id == target_task_id ->
            %{task | agent_id: agent_id}

          task.agent_id == agent_id ->
            %{task | agent_id: nil}

          true ->
            task
        end
      end)

    session
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_embed(:tasks, new_tasks)
    |> Repo.update()
  end

  @doc "Find the currently active task for a session."
  def active_task(%Session{} = session) do
    Session.active_task(session)
  end

  @doc "Find a task by agent ID within a session."
  def find_task_by_agent(%Session{} = session, agent_id) do
    Session.find_task_by_agent(session, agent_id)
  end

  # ============================================================================
  # Convenience: find-or-create session per conversation
  # ============================================================================

  @doc """
  Find an existing active session for this conversation, or create one.

  This is the main entry point for the agent task flow — ensures one
  session per Claude conversation.
  """
  def find_or_create_session(%Scope{} = scope, external_id, attrs \\ %{}) do
    case get_by_external_id(scope, external_id) do
      %Session{} = existing ->
        {:ok, existing}

      nil ->
        warn_on_concurrent_agent(scope, external_id)

        # The working copy comes off the scope (`X-Harness-Id`): a recorded
        # model turn arrives knowing only its harness, and this is the way back.
        attrs =
          attrs
          |> Map.put(:external_conversation_id, external_id)
          |> Map.put(:working_copy_id, scope.active_working_copy_id)

        create_session(scope, attrs)
    end
  end

  @doc """
  Claude's own session id for the session running in a working copy, or nil.

  The join between a turn addressed to a harness (all `/v1/messages` carries)
  and a conversation keyed on Claude's session id. Newest wins: only the
  current session is taking turns.
  """
  @spec external_id_for_harness(Ecto.UUID.t() | nil) :: String.t() | nil
  def external_id_for_harness(nil), do: nil

  def external_id_for_harness(working_copy_id) when is_binary(working_copy_id) do
    Session
    |> where(
      [s],
      s.working_copy_id == ^working_copy_id and not is_nil(s.external_conversation_id)
    )
    |> order_by([s], desc: s.inserted_at)
    |> limit(1)
    |> select([s], s.external_conversation_id)
    |> Repo.one()
  end

  @doc """
  Other active sessions on this project belonging to a different conversation.

  Two Claude Code sessions on one project corrupt task attribution (one used
  the other's session id). Detection only: refusing is a policy call.
  Filtered to sessions touched within `active_window_seconds/0`, because
  `status == :active` never goes stale.
  """
  @spec concurrent_sessions(Scope.t(), String.t()) :: [Session.t()]
  def concurrent_sessions(%Scope{active_project_id: project_id}, external_id)
      when is_binary(project_id) do
    cutoff = DateTime.add(DateTime.utc_now(), -@active_window_seconds, :second)

    from(s in Session,
      where:
        s.project_id == ^project_id and s.status == :active and
          s.external_conversation_id != ^external_id and
          not is_nil(s.external_conversation_id) and
          s.updated_at > ^cutoff
    )
    |> Repo.all()
  end

  def concurrent_sessions(_scope, _external_id), do: []

  defp warn_on_concurrent_agent(scope, external_id) do
    case concurrent_sessions(scope, external_id) do
      [] ->
        :ok

      others ->
        require Logger

        Logger.warning(
          "[Sessions] another agent is already active on this project — " <>
            "#{length(others)} session(s): " <>
            Enum.map_join(others, ", ", & &1.external_conversation_id) <>
            ". Concurrent agents corrupt task attribution and overwrite each other's files."
        )
    end
  end
end
