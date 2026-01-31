defmodule CodeMySpec.Documents.Parsers.SurfaceComponentParser do
  @moduledoc """
  Parse Surface Components section AST into component maps with type and story_ids.
  Used by architecture_proposal document type.
  """

  @spec from_ast(list()) :: [map()]
  def from_ast(ast) do
    ast
    |> group_by_h3()
    |> Enum.map(&parse_component/1)
  end

  defp group_by_h3(ast) do
    ast
    |> Enum.reduce({[], nil}, fn
      {"h3", _, content, _}, {components, current} ->
        module_name = extract_text(content)
        new_components = if current, do: [current | components], else: components
        {new_components, {module_name, []}}

      _element, {components, nil} ->
        {components, nil}

      element, {components, {module_name, content}} ->
        {components, {module_name, [element | content]}}
    end)
    |> case do
      {components, nil} -> Enum.reverse(components)
      {components, current} -> Enum.reverse([current | components])
    end
    |> Enum.map(fn {module_name, content} -> {module_name, Enum.reverse(content)} end)
  end

  defp parse_component({module_name, content}) do
    fields = extract_fields(content)

    %{
      name: module_name,
      type: fields["type"] || "live",
      description: fields["description"],
      story_ids: parse_story_ids(fields["stories"])
    }
  end

  defp extract_fields(ast) do
    # Extract from both list items and paragraphs
    list_fields =
      ast
      |> Enum.flat_map(&extract_list_items/1)
      |> Enum.map(&parse_field_line/1)
      |> Enum.reject(&is_nil/1)

    paragraph_fields =
      ast
      |> Enum.flat_map(&extract_paragraph_fields/1)
      |> Enum.reject(&is_nil/1)

    (list_fields ++ paragraph_fields)
    |> Map.new()
  end

  defp extract_list_items({"ul", _, items, _}) do
    Enum.map(items, fn {"li", _, content, _} -> extract_text(content) end)
  end

  defp extract_list_items(_), do: []

  defp extract_paragraph_fields({"p", _, content, _}) do
    text = extract_text(content)
    [parse_field_line(text)]
  end

  defp extract_paragraph_fields(_), do: []

  defp parse_field_line(text) do
    case Regex.run(~r/^\*\*(.+?):\*\*\s*(.*)$/, text) do
      [_, key, value] -> {String.downcase(key), String.trim(value)}
      _ -> nil
    end
  end

  defp parse_story_ids(nil), do: []
  defp parse_story_ids("_none_"), do: []

  defp parse_story_ids(text) do
    text
    |> String.split(~r/,\s*/)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&Integer.parse/1)
    |> Enum.map(fn
      {int, _} -> int
      :error -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_text(nodes) when is_list(nodes) do
    nodes |> Enum.map(&extract_text/1) |> Enum.join("") |> String.trim()
  end

  defp extract_text(text) when is_binary(text), do: text
  defp extract_text({"strong", _, content, _}), do: "**#{extract_text(content)}**"
  defp extract_text({"em", _, content, _}), do: "_#{extract_text(content)}_"
  defp extract_text({"code", _, content, _}), do: "`#{extract_text(content)}`"
  defp extract_text({_tag, _, content, _}), do: extract_text(content)
  defp extract_text(_), do: ""
end
