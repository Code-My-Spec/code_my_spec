defmodule CodeMySpec.AgentTasks.TrackEdits do
  @moduledoc """
  A Claude Code post-tool-use hook that tracks files edited during an agent session.

  When Claude uses Write or Edit tools, this hook captures the file path and stores
  it in session state, building a record of all files modified during the session
  for later validation.
  """

  require Logger

  alias CodeMySpec.FileEdits

  @edit_tools ~w(Write Edit)

  @doc """
  Process a tool use event and track file edits.

  Returns an empty map to allow tool execution to proceed.
  """
  @spec run(hook_input :: map()) :: map()
  def run(%{"tool_name" => tool, "tool_input" => input, "session_id" => session_id})
      when tool in @edit_tools do
    Logger.info("[TrackEdits] #{tool} tool detected (session: #{session_id})")

    case extract_file_path(input) do
      {:ok, file_path} ->
        FileEdits.track_edit(session_id, file_path)
        Logger.info("[TrackEdits] Tracked: #{file_path}")

      :error ->
        Logger.info("[TrackEdits] No file_path in input")
    end

    %{}
  end

  def run(%{"tool_name" => tool}) when tool in @edit_tools do
    Logger.info("[TrackEdits] #{tool} tool detected but no session_id, skipping")
    %{}
  end

  def run(%{"tool_name" => tool}) do
    Logger.info("[TrackEdits] Ignoring non-edit tool: #{tool}")
    %{}
  end

  def run(_hook_input) do
    Logger.info("[TrackEdits] No tool_name in input")
    %{}
  end

  defp extract_file_path(%{"file_path" => file_path}) when is_binary(file_path),
    do: {:ok, file_path}

  defp extract_file_path(_input), do: :error
end
