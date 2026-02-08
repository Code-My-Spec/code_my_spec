defmodule CodeMySpec.Transcripts.ClaudeCode.Entry do
  @moduledoc """
  Struct representing a single line entry in the Claude Code transcript JSONL.

  Maps to the raw JSON structure with type, role, and content fields. Each entry
  captures either a user message or an assistant response with associated metadata
  like timestamps, UUIDs for threading, and session context.

  ## Fields

    - `type` - Entry type indicating message origin ("user" or "assistant")
    - `uuid` - Unique identifier for this entry
    - `parent_uuid` - UUID of parent entry for threading (nil for root entries)
    - `timestamp` - ISO 8601 timestamp of when entry was created
    - `session_id` - Session identifier grouping related entries
    - `agent_id` - Agent identifier for the session
    - `cwd` - Current working directory at time of entry
    - `version` - Claude Code version that created the entry
    - `git_branch` - Git branch active at time of entry
    - `is_sidechain` - Whether entry is part of a sidechain conversation
    - `user_type` - Classification of user type ("external" or "internal")
    - `request_id` - API request ID (assistant entries only, format: "req_...")
    - `message` - Message content structure
  """

  @type t :: %__MODULE__{
          type: String.t(),
          uuid: String.t(),
          parent_uuid: String.t() | nil,
          timestamp: String.t(),
          session_id: String.t(),
          agent_id: String.t() | nil,
          cwd: String.t() | nil,
          version: String.t() | nil,
          git_branch: String.t() | nil,
          is_sidechain: boolean(),
          user_type: String.t() | nil,
          request_id: String.t() | nil,
          message: map()
        }

  @enforce_keys [:type, :uuid, :timestamp, :session_id, :message]
  defstruct [
    :type,
    :uuid,
    :parent_uuid,
    :timestamp,
    :session_id,
    :agent_id,
    :cwd,
    :version,
    :git_branch,
    :user_type,
    :request_id,
    :message,
    is_sidechain: false
  ]

  @doc """
  Create a new Entry struct from a decoded JSON map.

  Transforms camelCase JSON keys to snake_case struct fields.

  ## Parameters

    - `json` - Decoded JSON map with camelCase keys

  ## Returns

    A new Entry struct with all fields populated

  ## Examples

      iex> Entry.new(%{
      ...>   "type" => "user",
      ...>   "uuid" => "abc-123",
      ...>   "parentUuid" => nil,
      ...>   "timestamp" => "2024-01-01T00:00:00Z",
      ...>   "sessionId" => "session-456",
      ...>   "message" => %{"role" => "user", "content" => "Hello"}
      ...> })
      %Entry{type: "user", uuid: "abc-123", ...}
  """
  @spec new(map()) :: t()
  def new(json) when is_map(json) do
    %__MODULE__{
      type: json["type"],
      uuid: json["uuid"],
      parent_uuid: json["parentUuid"],
      timestamp: json["timestamp"],
      session_id: json["sessionId"],
      agent_id: json["agentId"],
      cwd: json["cwd"],
      version: json["version"],
      git_branch: json["gitBranch"],
      is_sidechain: json["isSidechain"] || false,
      user_type: json["userType"],
      request_id: json["requestId"],
      message: json["message"]
    }
  end

  @doc """
  Check if entry is a user message.

  ## Examples

      iex> Entry.user?(%Entry{type: "user", ...})
      true

      iex> Entry.user?(%Entry{type: "assistant", ...})
      false
  """
  @spec user?(t()) :: boolean()
  def user?(%__MODULE__{type: "user"}), do: true
  def user?(%__MODULE__{}), do: false

  @doc """
  Check if entry is an assistant message.

  ## Examples

      iex> Entry.assistant?(%Entry{type: "assistant", ...})
      true

      iex> Entry.assistant?(%Entry{type: "user", ...})
      false
  """
  @spec assistant?(t()) :: boolean()
  def assistant?(%__MODULE__{type: "assistant"}), do: true
  def assistant?(%__MODULE__{}), do: false

  @doc """
  Extract the content from an entry's message.

  Returns a string for user entries or a list of content blocks for assistant entries.

  ## Examples

      iex> Entry.content(%Entry{message: %{"content" => "Hello"}})
      "Hello"

      iex> Entry.content(%Entry{message: %{"content" => [%{"type" => "text", "text" => "Hi"}]}})
      [%{"type" => "text", "text" => "Hi"}]
  """
  @spec content(t()) :: String.t() | [map()] | nil
  def content(%__MODULE__{message: message}) when is_map(message) do
    message["content"]
  end

  def content(%__MODULE__{}), do: nil

  @doc """
  Extract the role from an entry's message.

  ## Examples

      iex> Entry.role(%Entry{message: %{"role" => "user"}})
      "user"

      iex> Entry.role(%Entry{message: %{"role" => "assistant"}})
      "assistant"
  """
  @spec role(t()) :: String.t() | nil
  def role(%__MODULE__{message: message}) when is_map(message) do
    message["role"]
  end

  def role(%__MODULE__{}), do: nil

  @doc """
  Extract tool use content blocks from an assistant entry.

  Returns an empty list for user entries or assistant entries without tool use.

  ## Examples

      iex> Entry.tool_use_blocks(%Entry{type: "assistant", message: %{"content" => [
      ...>   %{"type" => "tool_use", "name" => "Read", "input" => %{}}
      ...> ]}})
      [%{"type" => "tool_use", "name" => "Read", "input" => %{}}]

      iex> Entry.tool_use_blocks(%Entry{type: "user", ...})
      []
  """
  @spec tool_use_blocks(t()) :: [map()]
  def tool_use_blocks(%__MODULE__{type: "assistant", message: message}) when is_map(message) do
    message
    |> Map.get("content", [])
    |> filter_blocks_by_type("tool_use")
  end

  def tool_use_blocks(%__MODULE__{}), do: []

  @doc """
  Extract tool result content blocks from a user entry containing tool results.

  Returns an empty list for entries with string content or no tool results.

  ## Examples

      iex> Entry.tool_result_blocks(%Entry{message: %{"content" => [
      ...>   %{"type" => "tool_result", "tool_use_id" => "123", "content" => "result"}
      ...> ]}})
      [%{"type" => "tool_result", "tool_use_id" => "123", "content" => "result"}]

      iex> Entry.tool_result_blocks(%Entry{message: %{"content" => "Hello"}})
      []
  """
  @spec tool_result_blocks(t()) :: [map()]
  def tool_result_blocks(%__MODULE__{message: message}) when is_map(message) do
    case message["content"] do
      content when is_list(content) ->
        filter_blocks_by_type(content, "tool_result")

      _ ->
        []
    end
  end

  def tool_result_blocks(%__MODULE__{}), do: []

  defp filter_blocks_by_type(content, type) when is_list(content) do
    Enum.filter(content, fn
      %{"type" => ^type} -> true
      _ -> false
    end)
  end

  defp filter_blocks_by_type(_, _), do: []
end
