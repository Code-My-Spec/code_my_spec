defmodule CodeMySpec.Transcripts do
  @moduledoc """
  Parses Claude Code transcript JSONL files to extract tool usage information.

  Transcripts are append-only logs of agent interactions, stored as newline-delimited JSON.
  This context provides utilities for reading transcripts and extracting specific data such
  as file paths modified by Write or Edit tool calls, enabling hooks to validate files
  written during agent sessions.
  """

  alias CodeMySpec.Transcripts.ClaudeCode.FileExtractor
  alias CodeMySpec.Transcripts.ClaudeCode.Parser
  alias CodeMySpec.Transcripts.ClaudeCode.Transcript

  @doc """
  Parses a Claude Code transcript JSONL file from the given file path into a Transcript struct.

  ## Parameters

    - `path` - Path to the JSONL transcript file

  ## Returns

    - `{:ok, Transcript.t()}` - Successfully parsed transcript
    - `{:error, :file_not_found}` - File does not exist
    - `{:error, {:json_parse_error, line_number, reason}}` - JSON parsing failed on specific line

  ## Examples

      iex> Transcripts.parse("/path/to/transcript.jsonl")
      {:ok, %Transcript{path: "/path/to/transcript.jsonl", entries: [...]}}

      iex> Transcripts.parse("/nonexistent/file.jsonl")
      {:error, :file_not_found}
  """
  @spec parse(Path.t()) :: {:ok, Transcript.t()} | {:error, term()}
  defdelegate parse(path), to: Parser

  @doc """
  Extract the list of files that were edited during a Claude Code session.

  Returns unique file paths in chronological order of first occurrence.

  ## Parameters

    - `transcript` - The Transcript struct to extract files from

  ## Returns

    List of unique file paths that were modified (via Edit or Write tools)

  ## Examples

      iex> Transcripts.extract_edited_files(transcript)
      ["/src/main.ex", "/src/helper.ex"]
  """
  @spec extract_edited_files(Transcript.t()) :: [Path.t()]
  defdelegate extract_edited_files(transcript), to: FileExtractor

  @doc """
  Extract all tool calls from a transcript.

  Returns tool calls in chronological order as they appear in the transcript.

  ## Parameters

    - `transcript` - The Transcript struct to extract tool calls from

  ## Returns

    List of ToolCall structs representing all tool invocations

  ## Examples

      iex> Transcripts.get_tool_calls(transcript)
      [%ToolCall{name: "Read", ...}, %ToolCall{name: "Edit", ...}]
  """
  @spec get_tool_calls(Transcript.t()) :: [CodeMySpec.Transcripts.ClaudeCode.ToolCall.t()]
  defdelegate get_tool_calls(transcript), to: FileExtractor

  @doc """
  Extract tool calls filtered by tool name.

  Returns only tool calls matching the specified name (case-sensitive).

  ## Parameters

    - `transcript` - The Transcript struct to extract tool calls from
    - `tool_name` - The exact tool name to filter by (e.g., "Edit", "Write", "Read")

  ## Returns

    List of ToolCall structs matching the specified tool name

  ## Examples

      iex> Transcripts.get_tool_calls(transcript, "Edit")
      [%ToolCall{name: "Edit", ...}]

      iex> Transcripts.get_tool_calls(transcript, "edit")
      []  # Case-sensitive matching
  """
  @spec get_tool_calls(Transcript.t(), tool_name :: String.t()) ::
          [CodeMySpec.Transcripts.ClaudeCode.ToolCall.t()]
  defdelegate get_tool_calls(transcript, tool_name), to: FileExtractor
end
