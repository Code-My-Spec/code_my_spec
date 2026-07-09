defmodule CodeMySpec.Mail.HtmlSanitizer do
  @moduledoc """
  Scrubs inbound email HTML down to something safe to render inline, using
  Floki (already a project dependency — no extra runtime app to load).

  Email bodies are attacker-controllable, so before rendering we drop
  script-bearing and layout-hijacking tags outright, strip every inline event
  handler (`on*`), and neutralize `javascript:` / `vbscript:` / `data:text/html`
  URLs on links and images. What survives is ordinary formatting markup —
  paragraphs, lists, tables, links, images — which the mail view styles.
  """

  # Tags removed entirely (with their subtrees): active content, page chrome,
  # and anything that could execute or exfiltrate.
  @drop_tags ~w(script style iframe object embed link meta base form input
                textarea select button title head noscript svg math applet)

  @doc """
  Sanitized HTML fragment safe to render inline. Returns "" on garbage.

  Options:
    * `:rewrite_img` — a `(url -> url)` function applied to each remote
      (`http`/`https`) `<img src>`, so callers can route images through a proxy.
      Defaults to identity; `data:`/`cid:`/relative srcs are never rewritten.
  """
  @spec sanitize(term(), keyword()) :: String.t()
  def sanitize(html, opts \\ [])

  def sanitize(html, opts) when is_binary(html) do
    rewriter = Keyword.get(opts, :rewrite_img, & &1)

    case Floki.parse_fragment(html) do
      {:ok, tree} -> tree |> scrub(rewriter) |> Floki.raw_html()
      _ -> ""
    end
  end

  def sanitize(_, _opts), do: ""

  @doc "Plain-text extraction (for list-row snippets)."
  @spec to_text(term()) :: String.t()
  def to_text(html) when is_binary(html) do
    case Floki.parse_fragment(html) do
      {:ok, tree} -> Floki.text(tree)
      _ -> html
    end
  end

  def to_text(_), do: ""

  defp scrub(nodes, rewriter) when is_list(nodes) do
    nodes |> Enum.map(&scrub_node(&1, rewriter)) |> Enum.reject(&is_nil/1)
  end

  defp scrub_node(text, _rewriter) when is_binary(text), do: text
  defp scrub_node({:comment, _}, _rewriter), do: nil

  defp scrub_node({tag, attrs, children}, rewriter) when is_binary(tag) do
    t = String.downcase(tag)

    if t in @drop_tags do
      nil
    else
      {tag, scrub_attrs(attrs, t, rewriter), scrub(children, rewriter)}
    end
  end

  defp scrub_node(_other, _rewriter), do: nil

  defp scrub_attrs(attrs, tag, rewriter) do
    attrs
    |> Enum.reject(fn {name, _v} -> String.starts_with?(String.downcase(name), "on") end)
    |> Enum.map(fn {name, value} ->
      n = String.downcase(name)

      cond do
        n in ~w(href src xlink:href) and unsafe_url?(value) -> {name, "#"}
        tag == "img" and n == "src" -> {name, rewrite_remote(value, rewriter)}
        true -> {name, value}
      end
    end)
  end

  defp rewrite_remote(value, rewriter) when is_binary(value) do
    v = String.trim(value)

    if String.starts_with?(v, "http://") or String.starts_with?(v, "https://"),
      do: rewriter.(v),
      else: value
  end

  defp rewrite_remote(value, _rewriter), do: value

  defp unsafe_url?(value) when is_binary(value) do
    v = value |> String.trim() |> String.downcase()

    String.starts_with?(v, "javascript:") or
      String.starts_with?(v, "vbscript:") or
      String.starts_with?(v, "data:text/html")
  end

  defp unsafe_url?(_), do: false
end
