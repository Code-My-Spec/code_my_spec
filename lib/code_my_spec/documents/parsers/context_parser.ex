defmodule CodeMySpec.Documents.Parsers.ContextParser do
  @moduledoc """
  Parse Contexts section AST into context maps with children and story_ids.
  Used by architecture_proposal document type.
  """

  @spec from_ast(list()) :: [map()]
  def from_ast(ast) do
    ast
    |> group_by_h3()
    |> Enum.map(&parse_context/1)
  end

  defp group_by_h3(ast) do
    ast
    |> Enum.reduce({[], nil}, fn
      {"h3", _, content, _}, {contexts, current} ->
        module_name = extract_text(content)
        new_contexts = if current, do: [current | contexts], else: contexts
        {new_contexts, {module_name, []}}

      _element, {contexts, nil} ->
        {contexts, nil}

      element, {contexts, {module_name, content}} ->
        {contexts, {module_name, [element | content]}}
    end)
    |> case do
      {contexts, nil} -> Enum.reverse(contexts)
      {contexts, current} -> Enum.reverse([current | contexts])
    end
    |> Enum.map(fn {module_name, content} -> {module_name, Enum.reverse(content)} end)
  end

  defp parse_context({module_name, content}) do
    fields = extract_fields(content)
    # Try explicit **Description:** field first, then fall back to first paragraph
    description = fields["description"] || extract_leading_description(content)
    children = extract_children(content, module_name)

    %{
      name: module_name,
      description: description,
      story_ids: parse_story_ids(fields["stories"]),
      children: children
    }
  end

  # Extract description from first plain paragraph (not a field line)
  defp extract_leading_description(ast) do
    ast
    |> Enum.find_value(fn
      {"p", _, content, _} ->
        text = extract_text(content)
        # Skip if it's a field line like **Type:** or **Stories:**
        if Regex.match?(~r/^\*\*\w+:\*\*/, text) do
          nil
        else
          text
        end

      _ ->
        nil
    end)
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

  defp extract_children(ast, parent_module) do
    # Find content after H4 "Children" or **Children:** paragraph
    {_, after_children} =
      Enum.reduce(ast, {:before, []}, fn
        {"h4", _, content, _}, {:before, _} ->
          if extract_text(content) =~ ~r/children/i do
            {:after, []}
          else
            {:before, []}
          end

        {"p", _, content, _}, {:before, _} ->
          text = extract_text(content)

          if text =~ ~r/^\*\*Children:?\*\*/ do
            {:after, []}
          else
            {:before, []}
          end

        element, {:after, acc} ->
          {:after, [element | acc]}

        _, acc ->
          acc
      end)

    after_children
    |> Enum.reverse()
    |> Enum.flat_map(&extract_list_items/1)
    |> Enum.map(&parse_child_line(&1, parent_module))
    |> Enum.reject(&is_nil/1)
  end

  defp parse_child_line(text, _parent_module) do
    trimmed = String.trim(text)

    # Format with stories: Name (type) [Stories: X, Y]: Description
    case Regex.run(
           ~r/^`?([^`\(]+)`?\s*\(([^\)]+)\)\s*\[Stories:\s*([^\]]+)\](?:[\s:-]+(.+))?$/,
           trimmed
         ) do
      [_, name, type, stories_str, description] ->
        %{
          name: clean_name(name),
          type: type,
          description: description,
          story_ids: parse_story_ids(stories_str)
        }

      [_, name, type, stories_str] ->
        %{
          name: clean_name(name),
          type: type,
          description: nil,
          story_ids: parse_story_ids(stories_str)
        }

      _ ->
        # Fallback: Name (type) - Description or Name (type): Description
        case Regex.run(~r/^`?([^`\(]+)`?\s*\(([^\)]+)\)(?:[\s:-]+(.+))?$/, trimmed) do
          [_, name, type, description] ->
            %{
              name: clean_name(name),
              type: type,
              description: String.trim(description || ""),
              story_ids: []
            }

          [_, name, type] ->
            %{
              name: clean_name(name),
              type: type,
              description: nil,
              story_ids: []
            }

          _ ->
            nil
        end
    end
  end

  defp clean_name(name) do
    name
    |> String.trim()
    |> String.trim("`")
    |> String.trim()
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
