defmodule CodeMySpec.Documents.MarkdownParser do
  @moduledoc """
  Generic markdown parser that extracts H2 sections into a map.
  Supports pluggable section parsers via convention: section name maps to parser module.

  For example, "functions" section → CodeMySpec.Documents.Parsers.FunctionParser
  If no parser exists, falls back to text extraction.

  ## Implementation note

  Parsing is done by `MDEx` (Rust-backed) for speed, then converted to the
  Earmark-style tuple AST (`{tag, attrs, content, meta}`) that the section
  parsers and `extract_text/1` were written against. The converter keeps the
  per-parse cost at MDEx's ~1ms rather than Earmark's ~160ms.
  """

  @doc """
  Parses markdown content into a map of section names to content.

  H2 headings become section keys (lowercased), and all content between
  H2 headings becomes the section value.

  Sections with matching parsers (e.g., "functions" → FunctionParser) will be
  parsed into structured data. Others will be extracted as plain text.

  ## Examples

      iex> markdown = \"\"\"
      ...> # Title
      ...> ## Purpose
      ...> This is the purpose.
      ...> ## Fields
      ...> Field list here.
      ...> \"\"\"
      iex> MarkdownParser.parse(markdown)
      {:ok, %{"purpose" => "This is the purpose.", "fields" => [%Field{...}]}}
  """
  # GFM-equivalent extensions — matches what Earmark enabled by default.
  @mdex_opts [
    extension: [
      table: true,
      strikethrough: true,
      autolink: true,
      tasklist: true,
      superscript: true
    ]
  ]

  def parse(markdown_content) do
    case MDEx.parse_document(markdown_content, @mdex_opts) do
      {:ok, document} ->
        ast = document.nodes |> Enum.map(&to_earmark/1)
        sections = extract_sections(ast)
        {:ok, sections}

      {:error, reason} ->
        {:error, "Failed to parse markdown: #{inspect(reason)}"}
    end
  end

  # -- MDEx → Earmark-tuple AST conversion --------------------------------
  #
  # Earmark's AST shape is `{tag, attrs, content, meta}` where tag is a
  # string, attrs is a list, content is a list of children (strings or
  # nested tuples), and meta is `%{}`. The section parsers match this
  # shape literally, so we preserve it.

  defp to_earmark(%MDEx.Heading{level: level, nodes: children}) do
    {"h#{level}", [], convert_children(children), %{}}
  end

  defp to_earmark(%MDEx.Paragraph{nodes: children}) do
    {"p", [], convert_children(children), %{}}
  end

  defp to_earmark(%MDEx.Text{literal: text}), do: text

  defp to_earmark(%MDEx.List{list_type: :bullet, nodes: items}) do
    {"ul", [], Enum.map(items, &to_earmark/1), %{}}
  end

  defp to_earmark(%MDEx.List{list_type: :ordered, nodes: items}) do
    {"ol", [], Enum.map(items, &to_earmark/1), %{}}
  end

  defp to_earmark(%MDEx.ListItem{nodes: children}) do
    {"li", [], convert_children(children), %{}}
  end

  defp to_earmark(%MDEx.Table{nodes: rows}) do
    {header_rows, body_rows} = split_table_rows(rows)

    parts =
      []
      |> maybe_add_thead(header_rows)
      |> maybe_add_tbody(body_rows)

    {"table", [], parts, %{}}
  end

  defp to_earmark(%MDEx.TableRow{nodes: cells}) do
    {"tr", [], Enum.map(cells, &to_earmark/1), %{}}
  end

  defp to_earmark(%MDEx.TableCell{nodes: children}) do
    # Earmark doesn't distinguish th/td at cell level — the surrounding
    # thead/tbody wrapper does that. We emit td here and override to th
    # when the cell lives in a header row (see split_table_rows/1).
    {"td", [], convert_children(children), %{}}
  end

  defp to_earmark(%MDEx.Strong{nodes: children}),
    do: {"strong", [], convert_children(children), %{}}

  defp to_earmark(%MDEx.Emph{nodes: children}),
    do: {"em", [], convert_children(children), %{}}

  defp to_earmark(%MDEx.Code{literal: text}), do: {"code", [], [text], %{}}

  defp to_earmark(%MDEx.CodeBlock{literal: text, info: info}) do
    code_attrs = if info && info != "", do: [{"class", info}], else: []
    {"pre", [], [{"code", code_attrs, [String.trim_trailing(text, "\n")], %{}}], %{}}
  end

  defp to_earmark(%MDEx.Link{url: url, nodes: children}),
    do: {"a", [{"href", url}], convert_children(children), %{}}

  defp to_earmark(%MDEx.SoftBreak{}), do: " "
  defp to_earmark(%MDEx.LineBreak{}), do: {"br", [], [], %{}}
  defp to_earmark(%MDEx.HtmlInline{literal: text}), do: text
  defp to_earmark(%MDEx.HtmlBlock{literal: text}), do: text
  defp to_earmark(%MDEx.ThematicBreak{}), do: {"hr", [], [], %{}}

  defp to_earmark(%MDEx.BlockQuote{nodes: children}),
    do: {"blockquote", [], convert_children(children), %{}}

  defp to_earmark(%{nodes: children}), do: convert_children(children) |> wrap_unknown()
  defp to_earmark(_other), do: ""

  defp convert_children(children) when is_list(children) do
    Enum.map(children, &to_earmark/1)
  end

  defp wrap_unknown([single]) when is_binary(single), do: single
  defp wrap_unknown(list), do: {"div", [], list, %{}}

  defp split_table_rows(rows) do
    Enum.split_with(rows, fn
      %MDEx.TableRow{header: true} -> true
      _ -> false
    end)
  end

  defp maybe_add_thead(parts, []), do: parts

  defp maybe_add_thead(parts, [row | _]) do
    # Earmark emits a single thead containing one tr of th cells.
    {"tr", [], cells, %{}} = to_earmark(row)
    th_cells = Enum.map(cells, fn {"td", attrs, content, meta} -> {"th", attrs, content, meta} end)
    parts ++ [{"thead", [], [{"tr", [], th_cells, %{}}], %{}}]
  end

  defp maybe_add_tbody(parts, []), do: parts

  defp maybe_add_tbody(parts, rows) do
    parts ++ [{"tbody", [], Enum.map(rows, &to_earmark/1), %{}}]
  end

  # -- Section extraction (unchanged) -------------------------------------

  defp extract_sections(ast) do
    {sections, current} =
      ast
      |> Enum.reduce({%{}, nil}, fn
        {"h1", [], [_title], %{}}, {sections, current} ->
          # Skip H1, finalize previous section if any
          updated_sections = if current, do: finalize_section(sections, current), else: sections
          {updated_sections, nil}

        {"h2", [], [title], %{}}, {sections, current} ->
          # H2 defines sections
          key = String.downcase(String.trim(title))
          updated_sections = if current, do: finalize_section(sections, current), else: sections
          {updated_sections, {key, []}}

        _element, {sections, nil} ->
          {sections, nil}

        element, {sections, {key, content}} ->
          {sections, {key, [element | content]}}
      end)

    # Finalize the last section
    if current, do: finalize_section(sections, current), else: sections
  end

  defp finalize_section(sections, {key, content}) do
    reversed_content = Enum.reverse(content)

    value =
      case lookup_parser(key) do
        {:ok, parser_module} ->
          # Use convention-based parser
          parser_module.from_ast(reversed_content)

        :error ->
          # No parser found, extract as text
          extract_text(reversed_content)
      end

    Map.put(sections, key, value)
  end

  defp lookup_parser(section_key) do
    # Convention: "functions" → FunctionParser, "surface components" → SurfaceComponentParser
    # Split on spaces, singularize last word, camelize each part
    parser_name =
      section_key
      |> String.split(" ")
      |> Enum.map(&String.capitalize/1)
      |> then(fn parts ->
        # Singularize the last part
        {head, [last]} = Enum.split(parts, -1)
        head ++ [Inflex.singularize(last) |> String.capitalize()]
      end)
      |> Enum.join("")

    module_name = Module.concat([CodeMySpec.Documents.Parsers, "#{parser_name}Parser"])

    if Code.ensure_loaded?(module_name) and function_exported?(module_name, :from_ast, 1) do
      {:ok, module_name}
    else
      :error
    end
  end

  defp extract_text(ast) when is_list(ast) do
    ast
    |> Enum.map_join(" ", &extract_text/1)
    |> String.trim()
  end

  defp extract_text(text) when is_binary(text), do: text
  defp extract_text({"ol", [], items, %{}}), do: format_ordered_list(items)
  defp extract_text({"ul", [], items, %{}}), do: format_unordered_list(items)
  defp extract_text({"table", [], content, %{}}), do: format_table(content)
  defp extract_text({_tag, _attrs, content, %{}}), do: extract_text(content)
  defp extract_text(_), do: ""

  defp format_ordered_list(items) do
    items
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {item, index} ->
      case item do
        {"li", [], content, %{}} -> "#{index}. #{extract_text(content)}"
        {"p", [], content, %{}} -> "#{index}. #{extract_text(content)}"
        _ -> ""
      end
    end)
  end

  defp format_unordered_list(items) do
    items
    |> Enum.map_join("\n", fn item ->
      case item do
        {"li", [], content, %{}} -> "- #{extract_text(content)}"
        {"p", [], content, %{}} -> "- #{extract_text(content)}"
        _ -> ""
      end
    end)
  end

  defp format_table(content) do
    # Extract rows from table
    rows =
      content
      |> Enum.filter(fn
        {"tbody", _, _, %{}} -> true
        {"thead", _, _, %{}} -> true
        _ -> false
      end)
      |> Enum.flat_map(fn {_tag, _attrs, rows, %{}} -> rows end)

    rows
    |> Enum.map_join("\n", fn {"tr", _tr_attrs, cells, %{}} ->
      cells
      |> Enum.map_join(" | ", fn
        {"th", _th_attrs, cell_content, %{}} -> extract_text(cell_content)
        {"td", _td_attrs, cell_content, %{}} -> extract_text(cell_content)
      end)
    end)
  end
end
