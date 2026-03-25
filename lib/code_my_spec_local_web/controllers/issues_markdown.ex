defmodule CodeMySpecLocalWeb.IssuesMarkdown do
  @moduledoc """
  Markdown rendering for issues.

  Shared by both the LLM API (plain text) and the human UI (rendered via MDEx).
  """

  @doc "Render a list of issues as markdown."
  def index(issues, opts) do
    base = Keyword.fetch!(opts, :base_path)
    filters = Keyword.get(opts, :filters, %{})
    total = length(issues)

    header = "# Issues (#{total})\n"
    filter_note = render_filters(filters)

    if issues == [] do
      header <> filter_note <> "\nNo issues found.\n"
    else
      lines =
        Enum.map_join(issues, "\n", fn issue ->
          icon = status_icon(issue.status)
          sev = severity_badge(issue.severity)
          "- #{icon} #{sev} [#{issue.title}](#{base}/issues/#{issue.id}) — #{issue.scope}"
        end)

      header <> filter_note <> "\n" <> lines <> "\n"
    end
  end

  @doc "Render a single issue as markdown."
  def show(issue, opts) do
    base = Keyword.fetch!(opts, :base_path)

    back = "[← Back to issues](#{base}/issues)\n\n"

    parts = [
      "# #{issue.title}\n",
      "**ID:** #{issue.id}",
      "**Severity:** #{issue.severity}",
      "**Scope:** #{issue.scope}",
      "**Status:** #{issue.status}",
      story_line(issue, base),
      source_line(issue)
    ]

    parts =
      if issue.description && issue.description != "" do
        parts ++ ["\n## Description\n\n#{issue.description}"]
      else
        parts
      end

    parts =
      if issue.resolution && issue.resolution != "" do
        parts ++ ["\n## Resolution\n\n#{issue.resolution}"]
      else
        parts
      end

    back <> (parts |> Enum.reject(&is_nil/1) |> Enum.join("\n")) <> "\n"
  end

  # -- Helpers -----------------------------------------------------------------

  defp status_icon(:incoming), do: "🆕"
  defp status_icon(:accepted), do: "✅"
  defp status_icon(:dismissed), do: "🚫"
  defp status_icon(:resolved), do: "✔️"
  defp status_icon(_), do: "•"

  defp severity_badge(:critical), do: "**CRITICAL**"
  defp severity_badge(:high), do: "**HIGH**"
  defp severity_badge(:medium), do: "MEDIUM"
  defp severity_badge(:low), do: "low"
  defp severity_badge(:info), do: "info"
  defp severity_badge(_), do: ""

  defp story_line(%{story_id: nil}, _base), do: nil
  defp story_line(%{story_id: id}, base), do: "**Story:** [#{id}](#{base}/stories/#{id})"

  defp source_line(%{source_path: nil}), do: nil
  defp source_line(%{source_path: path}), do: "**Source:** `#{path}`"

  defp render_filters(filters) when map_size(filters) == 0, do: ""

  defp render_filters(filters) do
    parts =
      filters
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.map_join(", ", fn {k, v} -> "#{k}: `#{v}`" end)

    "\nFiltered by: #{parts}\n"
  end
end
