defmodule CodeMySpec.Documents.Parsers.IssueParser do
  @moduledoc """
  Parse Issues section AST into QaIssue structs.
  Extracts title + severity from H3 headings and description from body text.

  H3 heading format: `Issue title (SEVERITY)` — severity is extracted via regex.
  If no severity marker is found, defaults to "info".
  """

  alias CodeMySpec.Documents.QaIssue

  @spec from_ast(list()) :: [QaIssue.t()]
  def from_ast(ast) do
    ast
    |> group_by_h3()
    |> Enum.map(&parse_issue/1)
  end

  defp group_by_h3(ast) do
    ast
    |> Enum.reduce({[], nil}, fn
      {"h3", [], [title], %{}}, {issues, current} ->
        heading = String.trim(title)
        new_issues = if current, do: [current | issues], else: issues
        {new_issues, {heading, []}}

      _element, {issues, nil} ->
        {issues, nil}

      element, {issues, {heading, content}} ->
        {issues, {heading, [element | content]}}
    end)
    |> case do
      {issues, nil} -> Enum.reverse(issues)
      {issues, current} -> Enum.reverse([current | issues])
    end
    |> Enum.map(fn {heading, content} -> {heading, Enum.reverse(content)} end)
  end

  defp parse_issue({heading, content}) do
    {title, severity} = parse_heading(heading)

    %{title: title, severity: severity, description: extract_description(content)}
    |> then(&Ecto.embedded_load(QaIssue, &1, :json))
  end

  defp parse_heading(heading) do
    case Regex.run(~r/^(.+?)\s*\((\w+)\)\s*$/, heading) do
      [_, title, severity] -> {String.trim(title), String.downcase(severity)}
      _ -> {heading, "info"}
    end
  end

  defp extract_description(content) do
    content
    |> Enum.map_join(" ", &extract_text/1)
    |> String.trim()
  end

  defp extract_text(text) when is_binary(text), do: text
  defp extract_text({"p", [], text_content, %{}}), do: extract_text(text_content)
  defp extract_text({"strong", [], content, %{}}), do: extract_text(content)
  defp extract_text({"em", [], content, %{}}), do: extract_text(content)
  defp extract_text({"code", [], content, %{}}), do: extract_text(content)

  defp extract_text(content) when is_list(content) do
    Enum.map_join(content, " ", &extract_text/1)
  end

  defp extract_text({_tag, _attrs, content, %{}}), do: extract_text(content)
  defp extract_text(_), do: ""
end
