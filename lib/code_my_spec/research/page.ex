defmodule CodeMySpec.Research.Page do
  @moduledoc "What a fetch came back with, whatever kind of thing was at the URL."

  @enforce_keys [:url, :content]
  defstruct [:url, :fetched_url, :title, :content_type, :content, truncated: false]

  @type t :: %__MODULE__{
          url: String.t(),
          fetched_url: String.t(),
          title: String.t() | nil,
          content_type: String.t() | nil,
          content: String.t(),
          truncated: boolean()
        }

  @doc """
  Cuts `page` down to `limit` bytes and says so.

  Said in the page rather than left to the caller because a silent truncation
  reads as a complete document: an agent that gets the first half of an API
  reference and is not told will answer confidently about the half it has.
  """
  @spec truncate(t(), pos_integer() | :infinity) :: t()
  def truncate(%__MODULE__{} = page, :infinity), do: page

  def truncate(%__MODULE__{content: content} = page, limit) when byte_size(content) <= limit,
    do: page

  def truncate(%__MODULE__{content: content} = page, limit) do
    %{page | content: cut(content, limit), truncated: true}
  end

  # On a codepoint boundary, not a byte one. A cut through the middle of a
  # multi-byte character leaves invalid UTF-8, and invalid UTF-8 does not
  # survive JSON encoding — the MCP response fails to serialise and the agent
  # sees a transport error instead of a page
  # (`reference_mcp_strict_json_scrub`).
  defp cut(content, limit) do
    Enum.find_value(limit..max(limit - 3, 0)//-1, "", fn at ->
      candidate = binary_part(content, 0, at)
      if String.valid?(candidate), do: candidate
    end)
  end
end
