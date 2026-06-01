defmodule CodeMySpec.Transcripts.ClaudeCode.Parser do
  @moduledoc """
  Handles Claude Code JSONL file reading and line-by-line JSON parsing into Entry structs.

  Claude Code stores conversation transcripts as JSONL (newline-delimited JSON) files
  where each line represents a single interaction entry. This parser reads these files,
  validates the JSON structure, converts each line into an Entry struct, and constructs
  a Transcript struct containing all parsed entries in order.
  """

  alias CodeMySpec.Transcripts.ClaudeCode.Entry
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

      iex> Parser.parse("/path/to/transcript.jsonl")
      {:ok, %Transcript{path: "/path/to/transcript.jsonl", entries: [...]}}

      iex> Parser.parse("/nonexistent/file.jsonl")
      {:error, :file_not_found}
  """
  @spec parse(Path.t()) :: {:ok, Transcript.t()} | {:error, term()}
  def parse(path) do
    case read_lines(path) do
      {:ok, lines} ->
        parse_lines_to_transcript(path, lines)

      {:error, :enoent} ->
        {:error, :file_not_found}

      {:error, reason} ->
        {:error, {:read_error, reason}}
    end
  end

  @doc """
  Parses a single JSONL line into an Entry struct.

  ## Parameters

    - `line` - JSON string to parse
    - `line_number` - Line number for error reporting

  ## Returns

    - `{:ok, Entry.t()}` - Successfully parsed entry
    - `{:error, {:json_parse_error, line_number, reason}}` - JSON parsing failed

  ## Examples

      iex> Parser.parse_line(~s({"type": "user", "uuid": "123", ...}), 1)
      {:ok, %Entry{type: "user", ...}}

      iex> Parser.parse_line("{invalid json", 1)
      {:error, {:json_parse_error, 1, %Jason.DecodeError{...}}}
  """
  @spec parse_line(String.t(), pos_integer()) :: {:ok, Entry.t()} | {:error, term()}
  def parse_line(line, line_number) do
    case Jason.decode(line) do
      {:ok, json} ->
        entry = Entry.new(json)
        {:ok, entry}

      {:error, reason} ->
        {:error, {:json_parse_error, line_number, reason}}
    end
  end

  @doc """
  Reads a JSONL file and returns non-empty lines.

  ## Parameters

    - `path` - Path to the JSONL file

  ## Returns

    - `{:ok, [String.t()]}` - List of non-empty lines
    - `{:error, term()}` - File read error

  ## Examples

      iex> Parser.read_lines("/path/to/transcript.jsonl")
      {:ok, ["{...}", "{...}"]}

      iex> Parser.read_lines("/nonexistent/file.jsonl")
      {:error, :enoent}
  """
  @spec read_lines(Path.t()) :: {:ok, [String.t()]} | {:error, term()}
  def read_lines(path) do
    case File.read(path) do
      {:ok, content} ->
        lines =
          content
          |> String.split(~r/\r?\n/)
          |> Enum.map(&String.trim_trailing(&1, "\r"))
          |> Enum.filter(&non_empty_line?/1)

        {:ok, lines}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private functions

  defp parse_lines_to_transcript(path, lines) do
    lines
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {line, line_number}, {:ok, entries} ->
      case parse_line(line, line_number) do
        {:ok, entry} ->
          {:cont, {:ok, [entry | entries]}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} ->
        transcript = Transcript.new(path, Enum.reverse(entries))
        {:ok, transcript}

      {:error, _} = error ->
        error
    end
  end

  defp non_empty_line?(line) do
    String.trim(line) != ""
  end
end
