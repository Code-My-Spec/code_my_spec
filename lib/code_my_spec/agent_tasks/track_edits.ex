defmodule CodeMySpec.AgentTasks.TrackEdits do
  @moduledoc """
  A Claude Code post-tool-use hook that tracks files edited during an agent session.

  When Claude uses Write or Edit tools, this hook captures the file path and stores
  it in session state, building a record of all files modified during the session
  for later validation.
  """

  require Logger

  alias CodeMySpec.FileEdits
  alias CodeMySpec.Transcripts
  alias CodeMySpec.Transcripts.ClaudeCode.{Entry, ToolCall}

  @edit_tools ~w(Write Edit)

  @doc """
  Process a tool use event and track file edits.

  Returns an empty map to allow tool execution to proceed.
  """
  @spec run(hook_input :: map()) :: map()
  def run(%{"tool_name" => tool, "tool_input" => input, "session_id" => session_id} = hook_input)
      when tool in @edit_tools do
    agent_id = Map.get(hook_input, "agent_id")

    Logger.info(
      "[TrackEdits] #{tool} tool detected (session: #{session_id}, agent: #{agent_id || "main"})"
    )

    case extract_file_path(input) do
      {:ok, file_path} ->
        FileEdits.track_edit(session_id, file_path, agent_id)
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

  @doc """
  Extract edited file paths from a transcript file.

  Parses the transcript and returns all unique file paths from Write/Edit tool calls.
  Used at SubagentStop to get the file list directly without DB round-tripping.
  """
  @spec extract_files_from_transcript(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def extract_files_from_transcript(transcript_path) do
    Logger.info("[TrackEdits] Parsing transcript: #{transcript_path}")

    case Transcripts.parse(transcript_path) do
      {:ok, transcript} ->
        file_paths =
          transcript.entries
          |> Enum.filter(&Entry.assistant?/1)
          |> Enum.flat_map(&Entry.tool_use_blocks/1)
          |> Enum.map(&ToolCall.new/1)
          |> Enum.filter(&ToolCall.file_modifying?/1)
          |> Enum.map(&ToolCall.file_path/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        Logger.info("[TrackEdits] Found #{length(file_paths)} edited files in transcript")

        {:ok, file_paths}

      {:error, reason} ->
        Logger.warning(
          "[TrackEdits] Failed to parse transcript #{transcript_path}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp extract_file_path(%{"file_path" => file_path}) when is_binary(file_path),
    do: {:ok, file_path}

  defp extract_file_path(_input), do: :error
end
