defmodule CodeMySpec.FileEdits do
  @moduledoc """
  Tracks file edits by external session ID and optional agent ID.

  Files are always associated with a session. When edited by a sub-agent,
  the agent_id is also stored so files can be looked up per-agent for
  sub-agent validation, or per-session for main session validation.

  ## Agents that have no session

  An agent running under Alloy fires no hooks, so nothing ever calls
  `track_edit/3` for it and its edits were invisible — which is why
  `block_changed` could never narrow on that path and why every finding on the
  tree had to be treated as its own. `track_agent_edit/2` records for that case.

  `external_session_id` is NOT NULL and its unique index is
  `(external_session_id, file_path)`, so a session-less row still needs a value
  there. It gets `"agent:<id>"` — which is not a workaround so much as the
  truth: for an agent with no session, the agent *is* the unit of attribution,
  and using its id keeps one row per agent per file, exactly what the unique
  index is for. It also keeps these rows trivially separable from real session
  rows, which matters because `clear_edits/1` is keyed on that column.
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
  Record a file edit for an agent that has no session.

  Idempotent per agent and path, on the same unique index `track_edit/3` relies
  on. See the note in the moduledoc on why the session column carries
  `"agent:<id>"` rather than being made nullable.
  """
  @spec track_agent_edit(String.t(), String.t()) :: :ok
  def track_agent_edit(agent_id, file_path)
      when is_binary(agent_id) and is_binary(file_path) do
    track_edit(agent_session_id(agent_id), file_path, agent_id)
  end

  def track_agent_edit(_agent_id, _file_path), do: :ok

  @doc """
  Every path this agent has edited, across every session and none.

  Keyed on the agent alone rather than on session plus agent, which is what
  `get_edited_files_by_agent/2` answers. An agent under Alloy has no session to
  pair with, and an agent that outlived one should not lose what it wrote.

  The partial index on `agent_id` covers this.
  """
  @spec get_edited_files_for_agent(String.t()) :: [String.t()]
  def get_edited_files_for_agent(agent_id) when is_binary(agent_id) do
    FileEdit
    |> where([e], e.agent_id == ^agent_id)
    |> select([e], e.file_path)
    |> distinct(true)
    |> Repo.all()
  end

  def get_edited_files_for_agent(_agent_id), do: []

  @doc """
  Forget everything an agent has edited.

  For the end of a unit of work rather than the end of a turn — an agent is
  answerable for what it wrote until somebody decides it is not.
  """
  @spec clear_agent_edits(String.t()) :: :ok
  def clear_agent_edits(agent_id) when is_binary(agent_id) do
    FileEdit
    |> where([e], e.agent_id == ^agent_id)
    |> Repo.delete_all()

    :ok
  end

  def clear_agent_edits(_agent_id), do: :ok

  defp agent_session_id(agent_id), do: "agent:" <> agent_id

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
