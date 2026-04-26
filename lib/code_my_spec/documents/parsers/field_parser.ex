defmodule CodeMySpec.Documents.Parsers.FieldParser do
  @moduledoc """
  Parse Fields section table AST into Field embedded schema structs.
  """

  alias CodeMySpec.Documents.Field

  @spec from_ast(list()) :: [Field.t()]
  def from_ast(ast) do
    case find_table(ast) do
      nil -> []
      table -> parse_table(table)
    end
  end

  defp find_table(ast) do
    Enum.find(ast, &match?({"table", _, _, _}, &1))
  end

  defp parse_table({"table", [], table_parts, %{}}) do
    headers = extract_headers(table_parts)
    data_rows = extract_data_rows(table_parts)

    data_rows
    |> Enum.map(fn row ->
      Enum.zip(headers, row)
      |> Map.new()
      |> normalize_field_map()
      |> then(&Ecto.embedded_load(Field, &1, :json))
    end)
  end

  defp extract_headers(table_parts) do
    case Enum.find(table_parts, &match?({"thead", _, _, _}, &1)) do
      {"thead", [], [{"tr", [], cells, %{}}], %{}} ->
        Enum.map(cells, fn
          {"th", _attrs, content, %{}} ->
            extract_text(content) |> String.trim() |> String.downcase()
        end)

      _ ->
        []
    end
  end

  defp extract_data_rows(table_parts) do
    case Enum.find(table_parts, &match?({"tbody", _, _, _}, &1)) do
      {"tbody", [], rows, %{}} -> Enum.map(rows, &extract_row_cells/1)
      _ -> []
    end
  end

  defp extract_row_cells({"tr", [], cells, %{}}) do
    Enum.map(cells, &extract_cell_text/1)
  end

  defp extract_cell_text({"td", _attrs, content, %{}}) do
    extract_text(content) |> String.trim()
  end

  defp normalize_field_map(map) do
    # The table headers might be "Field", "Type", "Required", "Description", "Constraints"
    # We need to normalize them to match the Field schema fields
    %{
      field: Map.get(map, "field"),
      type: Map.get(map, "type"),
      required: Map.get(map, "required"),
      description: Map.get(map, "description"),
      constraints: Map.get(map, "constraints")
    }
  end

  defp extract_text(content) when is_list(content) do
    content
    |> Enum.map_join(" ", &extract_text/1)
    |> String.trim()
  end

  defp extract_text(text) when is_binary(text), do: text
  defp extract_text({"strong", [], content, %{}}), do: extract_text(content)
  defp extract_text({"em", [], content, %{}}), do: extract_text(content)
  defp extract_text({"code", [], content, %{}}), do: extract_text(content)
  defp extract_text({_tag, _attrs, content, %{}}), do: extract_text(content)
  defp extract_text(_), do: ""
end
