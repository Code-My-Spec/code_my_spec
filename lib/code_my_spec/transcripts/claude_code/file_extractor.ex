defmodule CodeMySpec.Transcripts.ClaudeCode.FileExtractor do
  @moduledoc """
  Analyzes Claude Code transcript entries to extract file modification information.

  Identifies Edit and Write tool calls and extracts their file_path parameters.
  Also provides utilities for extracting all tool calls or filtering by tool name.
  """

  alias CodeMySpec.Transcripts.ClaudeCode.Entry
  alias CodeMySpec.Transcripts.ClaudeCode.ToolCall
  alias CodeMySpec.Transcripts.ClaudeCode.Transcript

  @file_modifying_tools ~w(Edit Write)

  @doc """
  Extract the list of files that were edited during a Claude Code session.

  Returns unique file paths in chronological order of first occurrence.

  ## Parameters

    - `transcript` - The Transcript struct to extract files from

  ## Returns

    List of unique file paths that were modified (via Edit or Write tools)

  ## Examples

      iex> FileExtractor.extract_edited_files(transcript)
      ["/src/main.ex", "/src/helper.ex"]
  """
  @spec extract_edited_files(Transcript.t()) :: [Path.t()]
  def extract_edited_files(%Transcript{} = transcript) do
    transcript
    |> get_tool_calls()
    |> Enum.filter(&file_modifying?/1)
    |> Enum.map(&ToolCall.file_path/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc """
  Extract all tool calls from a transcript.

  Returns tool calls in chronological order as they appear in the transcript.

  ## Parameters

    - `transcript` - The Transcript struct to extract tool calls from

  ## Returns

    List of ToolCall structs representing all tool invocations

  ## Examples

      iex> FileExtractor.get_tool_calls(transcript)
      [%ToolCall{name: "Read", ...}, %ToolCall{name: "Edit", ...}]
  """
  @spec get_tool_calls(Transcript.t()) :: [ToolCall.t()]
  def get_tool_calls(%Transcript{entries: entries}) do
    entries
    |> Enum.filter(&Entry.assistant?/1)
    |> Enum.flat_map(&Entry.tool_use_blocks/1)
    |> Enum.map(&ToolCall.new/1)
  end

  @doc """
  Extract tool calls filtered by tool name.

  Returns only tool calls matching the specified name (case-sensitive).

  ## Parameters

    - `transcript` - The Transcript struct to extract tool calls from
    - `tool_name` - The exact tool name to filter by (e.g., "Edit", "Write", "Read")

  ## Returns

    List of ToolCall structs matching the specified tool name

  ## Examples

      iex> FileExtractor.get_tool_calls(transcript, "Edit")
      [%ToolCall{name: "Edit", ...}]

      iex> FileExtractor.get_tool_calls(transcript, "edit")
      []  # Case-sensitive matching
  """
  @spec get_tool_calls(Transcript.t(), tool_name :: String.t()) :: [ToolCall.t()]
  def get_tool_calls(%Transcript{} = transcript, tool_name) when is_binary(tool_name) do
    transcript
    |> get_tool_calls()
    |> Enum.filter(fn %ToolCall{name: name} -> name == tool_name end)
  end

  defp file_modifying?(%ToolCall{name: name}) when name in @file_modifying_tools, do: true
  defp file_modifying?(%ToolCall{}), do: false
end
