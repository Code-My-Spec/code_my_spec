defmodule CodeMySpec.Research.Html do
  @moduledoc """
  HTML to Markdown, for a reader that is an agent rather than a browser.

  ## Why this is written out rather than delegated

  Omni Tools calls `Html2Markdown.convert/1` here. Two reasons not to:

  A new dependency does not hot-reload — the running dev BEAM never loads a
  newly added application, so adding one crashes the live server for everyone
  on it until a restart (`reference_new_dep_crashes_live_dev`). Floki is
  already a dependency and does the parsing half.

  The larger reason is that a straight conversion is the wrong output. A
  modern page is mostly navigation, cookie banners, newsletter forms and
  footers; converted faithfully that is thousands of tokens of chrome wrapped
  around the paragraph the agent wanted, and it is charged for all of it. So
  this strips the furniture and prefers `main`/`article` when the page names
  one.

  Precision is explicitly not the goal — nobody renders this. Legible and
  small is.
  """

  # Never content. `head` is dropped wholesale after the title is taken out of
  # it, which is also what removes inline JSON-LD and CSS.
  #
  # The interactive half of this list was added after reading a real HexDocs
  # page: its search box and settings modal sit *inside* `<main>`, so selecting
  # the main region does not exclude them, and the first two hundred characters
  # an agent read were "Search documentation of Elixir / Elixir + libraries /
  # Settings". Controls are chrome wherever they are nested.
  # Decorative icons and collapsed panels — 75 of them on that one
  # page, each contributing text nobody can see.
  @furniture ~w(
               script style noscript template svg iframe
               form input select textarea button label
               nav header footer aside dialog menu search
             ) ++
               [
                 "[aria-hidden=true]",
                 "[hidden]",
                 "[role=navigation]",
                 "[role=search]",
                 "[role=dialog]",
                 "[role=banner]",
                 "[role=contentinfo]"
               ]

  # Checked in order; the first one present wins.
  @main_content ["main", "article", "[role=main]", "#content", "#main", ".post", ".markdown-body"]

  @doc """
  The page's title and its content as Markdown.

  Returns `{:error, :unparseable}` only if Floki cannot make a document of it,
  which in practice means it was not HTML at all.
  """
  @spec to_markdown(String.t()) ::
          {:ok, %{title: String.t() | nil, content: String.t()}} | {:error, :unparseable}
  def to_markdown(html) when is_binary(html) do
    case Floki.parse_document(html) do
      {:ok, document} ->
        title = title(document)

        content =
          document
          |> strip_furniture()
          |> main_content()
          |> render()
          |> tidy()

        {:ok, %{title: title, content: content}}

      {:error, _reason} ->
        {:error, :unparseable}
    end
  end

  defp title(document) do
    with [] <- Floki.find(document, "title"),
         [] <- Floki.find(document, "h1") do
      nil
    else
      [node | _] -> node |> Floki.text() |> squash() |> presence()
    end
  end

  defp strip_furniture(document) do
    Enum.reduce(@furniture, document, &Floki.filter_out(&2, &1))
  end

  defp main_content(document) do
    Enum.find_value(@main_content, fallback(document), fn selector ->
      case Floki.find(document, selector) do
        [] -> nil
        [node | _] -> [node]
      end
    end)
  end

  # `body` when there is one, because a document with no main region still has
  # a `head` full of meta tags whose text would otherwise lead the output.
  defp fallback(document) do
    case Floki.find(document, "body") do
      [] -> document
      [body | _] -> [body]
    end
  end

  defp render(nodes) when is_list(nodes), do: Enum.map_join(nodes, "", &render/1)
  defp render(text) when is_binary(text), do: text
  defp render({:comment, _content}), do: ""
  defp render({tag, attrs, children}), do: node(tag, attrs, children)
  defp render(_other), do: ""

  defp node(tag, _attrs, children) when tag in ~w(h1 h2 h3 h4 h5 h6) do
    level = tag |> String.last() |> String.to_integer()
    block(String.duplicate("#", level) <> " " <> inline(children))
  end

  defp node("br", _attrs, _children), do: "\n"
  defp node("hr", _attrs, _children), do: block("---")

  defp node("pre", _attrs, children) do
    block("```\n" <> (children |> Floki.text() |> String.trim()) <> "\n```")
  end

  defp node("code", _attrs, children) do
    case inline(children) do
      "" -> ""
      text -> "`" <> text <> "`"
    end
  end

  defp node("blockquote", _attrs, children) do
    quoted =
      children
      |> render()
      |> tidy()
      |> String.split("\n")
      |> Enum.map_join("\n", &("> " <> &1))

    block(quoted)
  end

  defp node("ul", _attrs, children) do
    children
    |> items()
    |> Enum.map_join("\n", &("- " <> &1))
    |> block()
  end

  defp node("ol", _attrs, children) do
    children
    |> items()
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {item, index} -> "#{index}. #{item}" end)
    |> block()
  end

  # A bare `li` outside a list, which happens in malformed markup.
  defp node("li", _attrs, children), do: "\n- " <> inline(children)

  defp node("a", attrs, children) do
    text = inline(children)

    case {text, href(attrs)} do
      {"", _href} -> ""
      {text, nil} -> text
      {text, href} -> "[#{text}](#{href})"
    end
  end

  defp node("img", attrs, _children) do
    case attr(attrs, "src") do
      nil -> ""
      src -> "![#{attr(attrs, "alt") || ""}](#{src})"
    end
  end

  defp node(tag, _attrs, children) when tag in ~w(strong b), do: emphasise(children, "**")
  defp node(tag, _attrs, children) when tag in ~w(em i), do: emphasise(children, "*")

  defp node("tr", _attrs, children) do
    cells = children |> Enum.map(&inline([&1])) |> Enum.reject(&(&1 == ""))

    case cells do
      [] -> ""
      cells -> "\n| " <> Enum.join(cells, " | ") <> " |"
    end
  end

  defp node(tag, _attrs, children) when tag in ~w(p div section table tbody thead article main),
    do: block(render(children))

  defp node(_tag, _attrs, children), do: render(children)

  defp emphasise(children, marker) do
    case inline(children) do
      "" -> ""
      text -> marker <> text <> marker
    end
  end

  defp items(children) do
    children
    |> Enum.filter(&match?({"li", _attrs, _children}, &1))
    |> Enum.map(fn {_tag, _attrs, kids} -> inline(kids) end)
    |> Enum.reject(&(&1 == ""))
  end

  # Anywhere a newline would break the construct it sits in — a heading, a list
  # item, a table cell.
  defp inline(children), do: children |> render() |> squash()

  defp block(""), do: ""
  defp block(content), do: "\n\n" <> content <> "\n\n"

  defp href(attrs) do
    case attr(attrs, "href") do
      nil -> nil
      "#" <> _fragment -> nil
      "javascript:" <> _rest -> nil
      href -> href
    end
  end

  defp attr(attrs, name) do
    Enum.find_value(attrs, fn
      {^name, value} -> value
      _other -> nil
    end)
  end

  defp squash(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp tidy(text) do
    text
    |> String.replace(~r/[ \t]+/u, " ")
    |> String.replace(~r/ *\n */u, "\n")
    |> String.replace(~r/\n{3,}/u, "\n\n")
    |> String.trim()
  end

  defp presence(""), do: nil
  defp presence(text), do: text
end
