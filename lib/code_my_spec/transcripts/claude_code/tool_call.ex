defmodule CodeMySpec.Transcripts.ClaudeCode.ToolCall do
  @moduledoc """
  Struct representing a Claude Code tool invocation extracted from the transcript.

  Contains the tool name, input parameters map, and optional result. Used by
  FileExtractor to analyze transcript entries and extract file modification information.

  ## Fields

    - `id` - Unique tool use ID for correlation (format: "toolu_...")
    - `name` - Name of the tool that was invoked (e.g. "Edit", "Write", "Read", "Bash")
    - `input` - Input parameters passed to the tool
    - `result` - Result returned from the tool invocation (may be nil)
  """

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          input: map(),
          result: any()
        }

  @enforce_keys [:id, :name, :input]
  defstruct [:id, :name, :input, :result]

  @file_modifying_tools ~w(Edit Write)

  @doc """
  Create a new ToolCall struct from a map of attributes.

  Accepts maps with either string or atom keys.

  ## Parameters

    - `attrs` - Map containing id, name, input, and optionally result

  ## Returns

    A new ToolCall struct

  ## Examples

      iex> ToolCall.new(%{"id" => "toolu_123", "name" => "Read", "input" => %{"file_path" => "/src/main.ex"}})
      %ToolCall{id: "toolu_123", name: "Read", input: %{"file_path" => "/src/main.ex"}, result: nil}

      iex> ToolCall.new(%{id: "toolu_456", name: "Edit", input: %{}, result: "success"})
      %ToolCall{id: "toolu_456", name: "Edit", input: %{}, result: "success"}
  """
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      id: get_attr(attrs, :id),
      name: get_attr(attrs, :name),
      input: get_attr(attrs, :input),
      result: get_attr(attrs, :result)
    }
  end

  defp get_attr(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, to_string(key))
  end

  @doc """
  Extract the file_path from a ToolCall's input if present.

  ## Parameters

    - `tool_call` - The ToolCall struct to extract file_path from

  ## Returns

    The file path if present in input, nil otherwise

  ## Examples

      iex> ToolCall.file_path(%ToolCall{input: %{"file_path" => "/src/main.ex"}, ...})
      "/src/main.ex"

      iex> ToolCall.file_path(%ToolCall{input: %{}, ...})
      nil
  """
  @spec file_path(t()) :: Path.t() | nil
  def file_path(%__MODULE__{input: input}) when is_map(input) do
    Map.get(input, "file_path")
  end

  def file_path(%__MODULE__{}), do: nil

  @doc """
  Check if the tool call modifies files (Edit or Write).

  ## Parameters

    - `tool_call` - The ToolCall struct to check

  ## Returns

    true if the tool is Edit or Write, false otherwise

  ## Examples

      iex> ToolCall.file_modifying?(%ToolCall{name: "Edit", ...})
      true

      iex> ToolCall.file_modifying?(%ToolCall{name: "Read", ...})
      false
  """
  @spec file_modifying?(t()) :: boolean()
  def file_modifying?(%__MODULE__{name: name}) when name in @file_modifying_tools, do: true
  def file_modifying?(%__MODULE__{}), do: false
end
