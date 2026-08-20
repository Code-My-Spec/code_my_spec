defmodule CodeMySpec.Sessions do
  @moduledoc """
  DB-backed session management.

  One session per Claude conversation. Tasks are tracked as embedded
  records within the session. The Sessions context is the public API
  boundary for all session and task operations.
  """

  import Ecto.Query, warn: false
  require Logger

  alias CodeMySpec.Repo
  alias CodeMySpec.Sessions.Session
  alias CodeMySpec.Sessions.SessionType
  alias CodeMySpec.Users.Scope

  # ============================================================================
  # PubSub — session/task lifecycle broadcasts (story 813)
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

  # Self-heal: tasks whose `session_type` references a renamed or
  # removed agent task module (e.g. legacy `QaPreflight`,
  # `ContextImplementation`) are stripped from the session and the
  # pruned tasks list is persisted. Keeps the read path resilient to
  # historical schema drift without requiring a manual data migration.
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

  Story 704 / Rule 1 + Rule 2. Idempotent on `agent_id`: calling twice
  for the same id refreshes `last_heartbeat_at` rather than appending.
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

  Story 704 / Rule 1. Removes the registration from the session's
  embedded `subagents` list. No-op if the agent was not registered.
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
  and stores the new hash. Story 538 / R8 — the stop hook reads the
  resulting count to detect a stuck loop.
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

  Story 538 / R8 — called from the `{:ok, :valid}` paths so the next
  failure starts a fresh streak.
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
  Atomically reassign a sub-agent: clear `agent_id` from any task that
  currently carries it (other than `target_task_id`) and set
  `agent_id` on the target task — in a single `Repo.update`.

  Story 704 / Rule 4. Used by `assign_subagent` so a partial-failure
  scenario can't leave the sub-agent unassigned from their old task
  while failing to land on the new one.
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

        # The working copy comes off the scope, which the harness's own
        # `X-Harness-Id` put there. A recorded model turn arrives knowing only
        # its harness, so without this there is no way back to the session and
        # every agent on the machine lands in one conversation.
        attrs =
          attrs
          |> Map.put(:external_conversation_id, external_id)
          |> Map.put(:harness_id, scope.active_harness_id)

        create_session(scope, attrs)
    end
  end

  @doc """
  Claude's own session id for the session running in a working copy, or nil.

  What a recorded model turn needs. The turn arrives addressed to a harness —
  that is all `/v1/messages` can carry, since nothing sits between Claude Code
  and the proxy to add more — and a conversation is keyed on Claude's session
  id. This is the join between the two.

  Newest wins. A working copy can have had several sessions over its life and
  only the current one is taking turns; ordering by insertion is what makes
  "the session in this checkout" mean the one running now.
  """
  @spec external_id_for_harness(Ecto.UUID.t() | nil) :: String.t() | nil
  def external_id_for_harness(nil), do: nil

  def external_id_for_harness(harness_id) when is_binary(harness_id) do
    Session
    |> where([s], s.harness_id == ^harness_id and not is_nil(s.external_conversation_id))
    |> order_by([s], desc: s.inserted_at)
    |> limit(1)
    |> select([s], s.external_conversation_id)
    |> Repo.one()
  end

  @doc """
  Other active sessions on this project belonging to a different conversation.

  A project is meant to have one agent working it. Two is not a race that
  resolves badly now and then — it corrupts the record. Observed: a second agent
  whose own MCP session had failed to register used the *only* session id it
  could find, which was the first agent's, so every start_task and evaluate_task
  it performed was attributed to the other agent, including a task it cancelled
  there. Both also wrote the same files; that composed by luck.

  Detection only. Refusing outright is a policy call — a desktop user and a
  sprite on one project may be legitimate — and silently proceeding was the
  thing that hurt, not the concurrency itself.
  """
  @spec concurrent_sessions(Scope.t(), String.t()) :: [Session.t()]
  def concurrent_sessions(%Scope{active_project_id: project_id}, external_id)
      when is_binary(project_id) do
    from(s in Session,
      where:
        s.project_id == ^project_id and s.status == :active and
          s.external_conversation_id != ^external_id and
          not is_nil(s.external_conversation_id)
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
