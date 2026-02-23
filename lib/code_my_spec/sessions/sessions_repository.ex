defmodule CodeMySpec.Sessions.SessionsRepository do
  @moduledoc """
  Filesystem-backed CRUD for sessions.

  Each session is stored as a directory under `.code_my_spec/sessions/{id}/`
  containing a `session.json` file. When a session reaches a terminal status
  (complete, failed, cancelled), it is moved to `.code_my_spec/sessions/completed/{id}/`.

  All file operations go through `CodeMySpec.Environments`
  to work across CLI, local, and VS Code environments.
  """

  alias CodeMySpec.Environments
  alias CodeMySpec.Sessions.Session

  @sessions_dir CodeMySpec.Paths.sessions_dir()
  @completed_sessions_dir CodeMySpec.Paths.completed_sessions_dir()
  @terminal_statuses [:complete, :failed, :cancelled]

  @doc """
  Create a new session directory and write session.json.
  """
  @spec create_session(Environments.Environment.t(), map()) ::
          {:ok, Session.t()} | {:error, term()}
  def create_session(env, attrs) do
    changeset = Session.changeset(%Session{}, attrs)

    if changeset.valid? do
      session = Ecto.Changeset.apply_changes(changeset)
      session_dir = Path.join(@sessions_dir, session.id)
      session_file = Path.join(session_dir, "session.json")

      # Create directory (write_file will create parent dirs)
      json_content = session |> Session.to_json() |> Jason.encode!()

      case Environments.write_file(env, session_file, json_content) do
        :ok -> {:ok, session}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, changeset}
    end
  end

  @doc """
  Read a session by ID from its directory.

  Checks the active sessions directory first, then the completed directory.
  """
  @spec get_session(Environments.Environment.t(), String.t()) ::
          {:ok, Session.t()} | {:error, :not_found}
  def get_session(env, id) do
    with {:error, :not_found} <- read_session_from(env, @sessions_dir, id) do
      read_session_from(env, @completed_sessions_dir, id)
    end
  end

  @doc """
  List all active sessions from the sessions directory.
  """
  @spec list_sessions(Environments.Environment.t()) :: {:ok, [Session.t()]}
  def list_sessions(env) do
    list_sessions_in(env, @sessions_dir)
  end

  @doc """
  List all completed sessions from the completed sessions directory.
  """
  @spec list_completed_sessions(Environments.Environment.t()) :: {:ok, [Session.t()]}
  def list_completed_sessions(env) do
    list_sessions_in(env, @completed_sessions_dir)
  end

  @doc """
  Update a session by rewriting its session.json.

  When the session status is terminal (complete, failed, cancelled), the session
  directory is moved from the active directory to the completed directory.
  """
  @spec update_session(Environments.Environment.t(), Session.t()) ::
          {:ok, Session.t()} | {:error, term()}
  def update_session(env, %Session{} = session) do
    session_file = Path.join([@sessions_dir, session.id, "session.json"])
    json_content = session |> Session.to_json() |> Jason.encode!()

    with true <- Environments.file_exists?(env, session_file),
         :ok <- Environments.write_file(env, session_file, json_content) do
      maybe_move_to_completed(env, session)
      {:ok, session}
    else
      false -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Remove a session directory and all its contents.

  Checks both active and completed directories.
  """
  @spec delete_session(Environments.Environment.t(), String.t()) :: :ok
  def delete_session(env, id) do
    # Remove from active dir
    active_path = resolve_dir_path(env, @sessions_dir, id)
    File.rm_rf(active_path)

    # Remove from completed dir
    completed_path = resolve_dir_path(env, @completed_sessions_dir, id)
    File.rm_rf(completed_path)

    :ok
  end

  @doc """
  Remove all session directories (both active and completed).
  """
  @spec clear_sessions(Environments.Environment.t()) :: :ok
  def clear_sessions(env) do
    clear_dir(env, @sessions_dir)
    clear_dir(env, @completed_sessions_dir)
    :ok
  end

  # Private helpers

  defp read_session_from(env, base_dir, id) do
    session_file = Path.join([base_dir, id, "session.json"])

    with {:ok, content} <- Environments.read_file(env, session_file),
         {:ok, json_map} <- Jason.decode(content),
         {:ok, session} <- Session.from_json(json_map) do
      {:ok, session}
    else
      _ -> {:error, :not_found}
    end
  end

  defp list_sessions_in(env, base_dir) do
    abs_path = resolve_base_path(env, base_dir)

    entries =
      case Environments.list_directory(env, abs_path) do
        {:ok, entries} -> entries
        {:error, _} -> []
      end

    sessions =
      Enum.flat_map(entries, fn entry_name ->
        case read_session_from(env, base_dir, entry_name) do
          {:ok, session} -> [session]
          {:error, _} -> []
        end
      end)

    {:ok, sessions}
  end

  defp maybe_move_to_completed(env, %Session{status: status, id: id})
       when status in @terminal_statuses do
    move_to_completed(env, id)
  end

  defp maybe_move_to_completed(_env, _session), do: :ok

  defp move_to_completed(env, session_id) do
    source = resolve_dir_path(env, @sessions_dir, session_id)
    completed_parent = resolve_base_path(env, @completed_sessions_dir)
    target = Path.join(completed_parent, session_id)

    File.mkdir_p!(completed_parent)
    File.rename(source, target)
  end

  defp clear_dir(env, base_dir) do
    abs_path = resolve_base_path(env, base_dir)

    case Environments.list_directory(env, abs_path) do
      {:ok, entries} ->
        Enum.each(entries, fn entry_name ->
          path = resolve_dir_path(env, base_dir, entry_name)
          File.rm_rf(path)
        end)

      {:error, _} ->
        :ok
    end
  end

  defp resolve_base_path(env, base_dir) do
    case env.cwd do
      nil -> base_dir
      working_dir -> Path.join(working_dir, base_dir)
    end
  end

  defp resolve_dir_path(env, base_dir, id) do
    case env.cwd do
      nil -> Path.join(base_dir, id)
      working_dir -> Path.join([working_dir, base_dir, id])
    end
  end
end
