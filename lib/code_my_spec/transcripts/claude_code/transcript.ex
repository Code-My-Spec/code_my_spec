defmodule CodeMySpec.Transcripts.ClaudeCode.Transcript do
  @moduledoc """
  Struct representing a parsed Claude Code transcript.

  Contains the file path and list of entries parsed from a JSONL transcript file.
  This struct is the primary data structure returned by the Parser module and
  consumed by the FileExtractor and other analysis modules.

  ## Fields

    - `path` - Absolute file path to the source JSONL file
    - `entries` - List of parsed Entry structs from the transcript
  """

  alias CodeMySpec.Transcripts.ClaudeCode.Entry

  @type t :: %__MODULE__{
          path: Path.t(),
          entries: [Entry.t()]
        }

  @enforce_keys [:path]
  defstruct [:path, entries: []]

  @doc """
  Create a new Transcript struct from keyword options.

  ## Parameters

    - `opts` - Keyword list with `:path` (required) and `:entries` (optional, defaults to `[]`)

  ## Returns

    A new Transcript struct

  ## Examples

      iex> Transcript.new(path: "/path/to/transcript.jsonl")
      %Transcript{path: "/path/to/transcript.jsonl", entries: []}

      iex> Transcript.new(path: "/path/to/transcript.jsonl", entries: [entry1, entry2])
      %Transcript{path: "/path/to/transcript.jsonl", entries: [entry1, entry2]}
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    path = Keyword.fetch!(opts, :path)
    entries = Keyword.get(opts, :entries, [])

    %__MODULE__{path: path, entries: entries}
  end

  @doc """
  Create a new Transcript struct from path and entries.

  ## Parameters

    - `path` - Absolute file path to the source JSONL file
    - `entries` - List of Entry structs

  ## Returns

    A new Transcript struct

  ## Examples

      iex> Transcript.new("/path/to/transcript.jsonl", [])
      %Transcript{path: "/path/to/transcript.jsonl", entries: []}

      iex> Transcript.new("/path/to/transcript.jsonl", [entry1, entry2])
      %Transcript{path: "/path/to/transcript.jsonl", entries: [entry1, entry2]}
  """
  @spec new(Path.t(), [Entry.t()]) :: t()
  def new(path, entries) when is_binary(path) and is_list(entries) do
    %__MODULE__{path: path, entries: entries}
  end
end
