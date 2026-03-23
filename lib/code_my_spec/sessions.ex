defmodule CodeMySpec.Sessions do
  @moduledoc """
  DB-backed session management.

  One session per Claude conversation. Tasks are tracked as embedded
  records within the session. The Sessions context is the public API
  boundary for all session and task operations.
  """

  import Ecto.Query, warn: false

  alias CodeMySpec.Repo
  alias CodeMySpec.Sessions.Session
  alias CodeMySpec.Users.Scope

  # ============================================================================
  # Session CRUD
  # ============================================================================

  @doc "Create a new session scoped to the user's project."
  def create_session(%Scope{} = scope, attrs) do
    %Session{}
    |> Session.scoped_changeset(attrs, scope)
    |> Repo.insert()
  end

  @doc "Get a session by ID, scoped to project."
  def get_session(%Scope{} = scope, id) do
    Session
    |> where([s], s.id == ^id and s.project_id == ^scope.active_project_id)
    |> Repo.one()
  end

  @doc "List all sessions for the project."
  def list_sessions(%Scope{} = scope) do
    Session
    |> where([s], s.project_id == ^scope.active_project_id)
    |> order_by([s], desc: s.inserted_at)
    |> Repo.all()
  end

  @doc "List active sessions for the project."
  def list_active_sessions(%Scope{} = scope) do
    Session
    |> where([s], s.project_id == ^scope.active_project_id and s.status == :active)
    |> order_by([s], desc: s.inserted_at)
    |> Repo.all()
  end

  @doc "Find an active session by external conversation ID (Claude session ID)."
  def get_by_external_id(%Scope{} = scope, external_id) when is_binary(external_id) do
    Session
    |> where([s],
      s.external_conversation_id == ^external_id and
        s.project_id == ^scope.active_project_id and
        s.status == :active
    )
    |> order_by([s], desc: s.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc "Update a session."
  def update_session(%Scope{} = _scope, %Session{} = session, attrs) do
    session
    |> Session.changeset(attrs)
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
    attrs =
      task_attrs
      |> Map.put_new(:id, Ecto.UUID.generate())
      |> Map.put(:status, :prepared)

    session
    |> Session.add_task(attrs)
    |> Repo.update()
  end

  @doc """
  Activate a prepared task (status: :prepared → :active).

  Called by start-task when the agent commits to working on it.
  Returns `{:ok, updated_session}` or `{:error, changeset}`.
  """
  def activate_task(%Scope{} = _scope, %Session{} = session, task_id, agent_id \\ nil) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    updates =
      %{status: :active, started_at: now}
      |> then(fn m -> if agent_id, do: Map.put(m, :agent_id, agent_id), else: m end)

    session
    |> Session.update_task(task_id, updates)
    |> Repo.update()
  end

  @doc """
  Complete a task (mark as :completed or :failed).

  Returns `{:ok, updated_session}` or `{:error, changeset}`.
  """
  def complete_task(%Scope{} = _scope, %Session{} = session, task_id, result \\ :completed)
      when result in [:completed, :failed, :cancelled] do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    session
    |> Session.update_task(task_id, %{status: result, completed_at: now})
    |> Repo.update()
  end

  @doc "Assign an agent_id to an active task."
  def assign_agent(%Scope{} = _scope, %Session{} = session, task_id, agent_id) do
    session
    |> Session.update_task(task_id, %{agent_id: agent_id})
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
        create_session(scope, Map.put(attrs, :external_conversation_id, external_id))
    end
  end
end
