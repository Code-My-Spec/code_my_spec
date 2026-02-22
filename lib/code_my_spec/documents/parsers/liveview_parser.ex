defmodule CodeMySpec.Documents.Parsers.LiveviewParser do
  @moduledoc """
  Parse LiveViews section AST into SpecComponent structs.
  Extracts module names (from H3 headings) and descriptions.
  Used by live_context_spec document type.
  """

  alias CodeMySpec.Documents.SpecComponent

  @spec from_ast(list()) :: [SpecComponent.t()]
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
    %{
      module_name: module_name,
      description: extract_description(content)
    }
    |> then(&Ecto.embedded_load(SpecComponent, &1, :json))
  end

  defp extract_description(content) do
    content
    |> Enum.find_value(fn
      {"p", _, text_content, _} ->
        text = extract_text(text_content)
        # Skip field lines like **Route:** or **Description:**
        if Regex.match?(~r/^\*\*\w+:\*\*/, text) do
          nil
        else
          text
        end

      _ ->
        nil
    end) || extract_description_field(content) || ""
  end

  defp extract_description_field(content) do
    content
    |> Enum.find_value(fn
      {"ul", _, items, _} ->
        Enum.find_value(items, fn {"li", _, item_content, _} ->
          item_content |> extract_text() |> match_description_field()
        end)

      {"p", _, text_content, _} ->
        text_content |> extract_text() |> match_description_field()

      _ ->
        nil
    end)
  end

  defp match_description_field(text) do
    case Regex.run(~r/^\*\*Description:\*\*\s*(.+)$/, text) do
      [_, desc] -> String.trim(desc)
      _ -> nil
    end
  end

  defp extract_text(content) when is_list(content) do
    content
    |> Enum.map_join("", &extract_text/1)
    |> String.trim()
  end

  defp extract_text(text) when is_binary(text), do: text
  defp extract_text({"strong", _, content, _}), do: "**#{extract_text(content)}**"
  defp extract_text({"em", _, content, _}), do: "_#{extract_text(content)}_"
  defp extract_text({"code", _, content, _}), do: "`#{extract_text(content)}`"
  defp extract_text({_tag, _attrs, content, _}), do: extract_text(content)
  defp extract_text(_), do: ""
end
