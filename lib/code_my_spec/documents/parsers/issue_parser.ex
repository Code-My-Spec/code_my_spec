defmodule CodeMySpec.Documents.Parsers.IssueParser do
  @moduledoc """
  Parse Issues section AST into QaIssue structs.

  Each issue is an H3 heading (title) with H4 subsections for structured fields:

      ### Issue title
      #### Severity
      MEDIUM
      #### Description
      What went wrong...

  Required H4 sections: Severity, Description.
  Severity must be one of: CRITICAL, HIGH, MEDIUM, LOW, INFO (case-insensitive).
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
      {"h3", _attrs, title_parts, %{}}, {issues, current} ->
        heading = extract_heading_text(title_parts)
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
    fields = group_by_h4(content)

    severity =
      case Map.get(fields, "severity") do
        nil -> nil
        text -> text |> String.trim() |> String.downcase()
      end

    description =
      case Map.get(fields, "description") do
        nil -> extract_text_from_ast(content)
        text -> text
      end

    scope =
      case Map.get(fields, "scope") do
        nil -> "app"
        text -> text |> String.trim() |> String.downcase()
      end

    %{title: heading, severity: severity, description: description, scope: scope}
    |> then(&Ecto.embedded_load(QaIssue, &1, :json))
  end

  defp group_by_h4(content) do
    {sections, current} =
      Enum.reduce(content, {%{}, nil}, fn
        {"h4", _attrs, title_parts, %{}}, {sections, current} ->
          key = extract_heading_text(title_parts) |> String.downcase()
          updated = if current, do: finalize_h4(sections, current), else: sections
          {updated, {key, []}}

        _element, {sections, nil} ->
          {sections, nil}

        element, {sections, {key, acc}} ->
          {sections, {key, [element | acc]}}
      end)

    if current, do: finalize_h4(sections, current), else: sections
  end

  defp finalize_h4(sections, {key, content}) do
    text =
      content
      |> Enum.reverse()
      |> extract_text_from_ast()
      |> String.trim()

    Map.put(sections, key, text)
  end

  defp extract_heading_text(parts) when is_list(parts) do
    Enum.map_join(parts, "", &extract_text/1) |> String.trim()
  end

  defp extract_heading_text(text) when is_binary(text), do: String.trim(text)

  defp extract_text_from_ast(content) when is_list(content) do
    Enum.map_join(content, " ", &extract_text/1) |> String.trim()
  end

  defp extract_text(text) when is_binary(text), do: text
  defp extract_text({"p", _attrs, text_content, %{}}), do: extract_text_from_ast(text_content)
  defp extract_text({"strong", _attrs, content, %{}}), do: extract_text_from_ast(content)
  defp extract_text({"em", _attrs, content, %{}}), do: extract_text_from_ast(content)
  defp extract_text({"code", _attrs, content, %{}}), do: extract_text_from_ast(content)

  defp extract_text(content) when is_list(content) do
    Enum.map_join(content, " ", &extract_text/1)
  end

  defp extract_text({_tag, _attrs, content, %{}}), do: extract_text_from_ast(content)
  defp extract_text(_), do: ""
end
