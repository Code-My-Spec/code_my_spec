defmodule CodeMySpec.Research.Fetch.Default do
  @moduledoc """
  Everything without a strategy of its own. Adapted from Omni Tools
  (Apache-2.0): HTML becomes Markdown, JSON is pretty-printed, text passes
  through, anything else is described rather than dumped.
  """

  @behaviour CodeMySpec.Research.Fetch.Strategy

  alias CodeMySpec.Research.{Html, Page}

  @text_types ~w(text/plain text/markdown text/csv text/x-markdown application/x-yaml text/yaml)

  @impl true
  def matches?(_uri), do: true

  @impl true
  def prepare(url, _uri), do: url

  @impl true
  def extract(%Req.Response{} = response, requested, fetched) do
    content_type = content_type(response)

    page = %Page{
      url: requested,
      fetched_url: fetched_url(response, fetched),
      content_type: content_type,
      content: ""
    }

    {:ok, body(page, content_type, response.body)}
  end

  @doc """
  The content type with its parameters dropped, lowercased.

  Public because `Reddit` needs the same reading of the same header, and a
  second implementation of "split on `;`, take the first part" is a second
  place for `text/html; charset=UTF-8` to be mistaken for a type nobody knows.
  """
  @spec content_type(Req.Response.t()) :: String.t()
  def content_type(%Req.Response{} = response) do
    case Req.Response.get_header(response, "content-type") do
      [value | _rest] ->
        value |> String.split(";") |> List.first() |> String.trim() |> String.downcase()

      [] ->
        "application/octet-stream"
    end
  end

  @doc """
  Where the response actually came from.

  The URL that was requested, unless Req followed redirects, in which case
  where they ended.
  """
  @spec fetched_url(Req.Response.t(), String.t()) :: String.t()
  def fetched_url(%Req.Response{} = response, fetched) do
    case response.private[:req_final_uri] do
      %URI{} = uri -> URI.to_string(uri)
      _other -> fetched
    end
  end

  defp body(page, "text/html", html) when is_binary(html) do
    case Html.to_markdown(html) do
      {:ok, %{title: title, content: content}} -> %{page | title: title, content: content}
      {:error, :unparseable} -> %{page | content: html}
    end
  end

  # Req decodes JSON for us when it recognises the type, so the body arriving
  # as a map is the normal case and the binary clause is the one that fires
  # when a server labels JSON something else.
  defp body(page, type, decoded)
       when type in ["application/json", "text/json"] and not is_binary(decoded),
       do: %{page | content: encode(decoded)}

  defp body(page, type, json)
       when type in ["application/json", "text/json"] and is_binary(json) do
    case Jason.decode(json) do
      {:ok, decoded} -> %{page | content: encode(decoded)}
      {:error, _reason} -> %{page | content: json}
    end
  end

  defp body(page, type, text) when is_binary(text) do
    cond do
      type in @text_types -> %{page | content: text}
      String.starts_with?(type, "text/") -> %{page | content: text}
      String.valid?(text) and String.starts_with?(type, "application/") -> %{page | content: text}
      # Binary. Describing it is the whole point: an agent handed a megabyte of
      # PNG bytes as a "page" spends its context on noise and learns nothing.
      true -> %{page | content: describe(type, text)}
    end
  end

  defp body(page, _type, other), do: %{page | content: encode(other)}

  defp encode(term) do
    case Jason.encode(term, pretty: true) do
      {:ok, json} -> json
      {:error, _reason} -> inspect(term, pretty: true, limit: :infinity)
    end
  end

  defp describe(type, binary) do
    "[#{type}, #{size(byte_size(binary))} — not text, so not shown]"
  end

  defp size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp size(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp size(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"
end
