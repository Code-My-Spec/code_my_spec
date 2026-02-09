defmodule CodeMySpec.FileEdits do
  @moduledoc """
  Tracks file edits by external session ID and optional agent ID.

  Files are always associated with a session. When edited by a sub-agent,
  the agent_id is also stored so files can be looked up per-agent for
  sub-agent validation, or per-session for main session validation.
  """

  import Ecto.Query
  alias CodeMySpec.FileEdits.FileEdit
  alias CodeMySpec.Repo

  @doc """
  Record a file edit for an external session, optionally scoped to an agent.
  Ignores duplicates (same session + agent + file_path).
  """
  @spec track_edit(String.t(), String.t(), String.t() | nil) :: :ok
  def track_edit(external_session_id, file_path, agent_id \\ nil) do
    %FileEdit{}
    |> Ecto.Changeset.change(
      external_session_id: external_session_id,
      agent_id: agent_id,
      file_path: file_path
    )
    |> Repo.insert(on_conflict: :nothing)

    :ok
  end

  @doc """
  Get all file paths edited in an external session.
  """
  @spec get_edited_files(String.t()) :: [String.t()]
  def get_edited_files(external_session_id) do
    FileEdit
    |> where([e], e.external_session_id == ^external_session_id)
    |> select([e], e.file_path)
    |> distinct(true)
    |> Repo.all()
  end

  @doc """
  Get file paths edited by a specific agent within a session.
  """
  @spec get_edited_files_by_agent(String.t(), String.t()) :: [String.t()]
  def get_edited_files_by_agent(external_session_id, agent_id) do
    FileEdit
    |> where([e], e.external_session_id == ^external_session_id and e.agent_id == ^agent_id)
    |> select([e], e.file_path)
    |> Repo.all()
  end

  @doc """
  Clear all edits for an external session.
  """
  @spec clear_edits(String.t()) :: :ok
  def clear_edits(external_session_id) do
    FileEdit
    |> where([e], e.external_session_id == ^external_session_id)
    |> Repo.delete_all()

    :ok
  end

  @doc """
  Remove specific file paths from tracking for an external session.
  Used to clean up validated files that passed all checks.

  When agent_id is provided, only removes records for that agent.
  Otherwise removes all matching records regardless of agent.
  """
  @spec remove_edited_files(String.t(), [String.t()], String.t() | nil) :: :ok
  def remove_edited_files(external_session_id, file_paths, agent_id \\ nil)

  def remove_edited_files(_external_session_id, [], _agent_id), do: :ok

  def remove_edited_files(external_session_id, file_paths, nil) when is_list(file_paths) do
    FileEdit
    |> where([e], e.external_session_id == ^external_session_id)
    |> where([e], e.file_path in ^file_paths)
    |> Repo.delete_all()

    :ok
  end

  def remove_edited_files(external_session_id, file_paths, agent_id) when is_list(file_paths) do
    FileEdit
    |> where([e], e.external_session_id == ^external_session_id and e.agent_id == ^agent_id)
    |> where([e], e.file_path in ^file_paths)
    |> Repo.delete_all()

    :ok
  end

  @doc """
  List all file edit records.
  """
  @spec list_all() :: [FileEdit.t()]
  def list_all do
    Repo.all(FileEdit)
  end

  @doc """
  Delete all file edit records.
  """
  @spec truncate_all() :: :ok
  def truncate_all do
    Repo.delete_all(FileEdit)
    :ok
  end
end
