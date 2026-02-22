defmodule CodeMySpec.Sessions.SessionsRepository do
  @moduledoc """
  Filesystem-backed CRUD for sessions.

  Each session is stored as a directory under `.code_my_spec/sessions/{id}/`
  containing a `session.json` file. All file operations go through `CodeMySpec.Environments`
  to work across CLI, local, and VS Code environments.
  """

  alias CodeMySpec.Environments
  alias CodeMySpec.Sessions.Session

  @sessions_dir CodeMySpec.Paths.sessions_dir()

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
  """
  @spec get_session(Environments.Environment.t(), String.t()) ::
          {:ok, Session.t()} | {:error, :not_found}
  def get_session(env, id) do
    session_file = Path.join([@sessions_dir, id, "session.json"])

    with {:ok, content} <- Environments.read_file(env, session_file),
         {:ok, json_map} <- Jason.decode(content),
         {:ok, session} <- Session.from_json(json_map) do
      {:ok, session}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  List all sessions from the sessions directory.
  """
  @spec list_sessions(Environments.Environment.t()) :: {:ok, [Session.t()]}
  def list_sessions(env) do
    # Get absolute path for list_directory (it doesn't use env.ref.working_dir)
    sessions_path = resolve_sessions_path(env)

    entries =
      case Environments.list_directory(env, sessions_path) do
        {:ok, entries} -> entries
        {:error, _} -> []
      end

    sessions =
      Enum.flat_map(entries, fn entry_name ->
        case get_session(env, entry_name) do
          {:ok, session} -> [session]
          {:error, _} -> []
        end
      end)

    {:ok, sessions}
  end

  @doc """
  Update a session by rewriting its session.json.
  """
  @spec update_session(Environments.Environment.t(), Session.t()) ::
          {:ok, Session.t()} | {:error, term()}
  def update_session(env, %Session{} = session) do
    session_file = Path.join([@sessions_dir, session.id, "session.json"])

    case Environments.file_exists?(env, session_file) do
      true ->
        json_content = session |> Session.to_json() |> Jason.encode!()

        case Environments.write_file(env, session_file, json_content) do
          :ok -> {:ok, session}
          {:error, reason} -> {:error, reason}
        end

      false ->
        {:error, :not_found}
    end
  end

  @doc """
  Remove a session directory and all its contents.
  """
  @spec delete_session(Environments.Environment.t(), String.t()) :: :ok
  def delete_session(env, id) do
    session_dir_path = resolve_session_dir_path(env, id)

    # File.rm_rf returns {:ok, files_and_dirs} on success
    # We always return :ok (idempotent)
    File.rm_rf(session_dir_path)
    :ok
  end

  @doc """
  Remove all session directories.
  """
  @spec clear_sessions(Environments.Environment.t()) :: :ok
  def clear_sessions(env) do
    sessions_path = resolve_sessions_path(env)

    case Environments.list_directory(env, sessions_path) do
      {:ok, entries} ->
        Enum.each(entries, fn entry_name ->
          delete_session(env, entry_name)
        end)

        :ok

      {:error, _} ->
        :ok
    end
  end

  # Private helpers

  defp resolve_sessions_path(env) do
    case env.cwd do
      nil -> @sessions_dir
      working_dir -> Path.join(working_dir, @sessions_dir)
    end
  end

  defp resolve_session_dir_path(env, id) do
    case env.cwd do
      nil -> Path.join(@sessions_dir, id)
      working_dir -> Path.join([working_dir, @sessions_dir, id])
    end
  end
end
