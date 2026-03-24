defmodule CodeMySpecLocalWeb.StoriesMarkdown do
  @moduledoc """
  Markdown rendering for stories.

  Shared by both the LLM API (plain text) and the human UI (rendered via MDEx).
  """

  @doc """
  Render a paginated list of stories as markdown.

  Options:
  - `:page` — current page number
  - `:total_pages` — total number of pages
  - `:total` — total story count
  - `:search` — active search filter (or nil)
  - `:base_path` — URL prefix for links (e.g. "/projects/my-project" or "/api/projects/my-project")
  """
  def index(stories, opts) do
    page = Keyword.fetch!(opts, :page)
    total_pages = Keyword.fetch!(opts, :total_pages)
    total = Keyword.fetch!(opts, :total)
    search = Keyword.get(opts, :search)
    base = Keyword.fetch!(opts, :base_path)

    header = "# Stories (#{total} total, page #{page}/#{total_pages})\n"
    search_note = if search, do: "\nFiltered by: `#{search}`\n", else: ""

    story_sections =
      Enum.map_join(stories, "\n\n---\n\n", fn story ->
        story_summary(story, base)
      end)

    nav = pagination_nav(page, total_pages, base)

    header <> search_note <> "\n" <> story_sections <> nav <> "\n"
  end

  @doc """
  Render a single story detail page as markdown.

  Options:
  - `:base_path` — URL prefix for links
  """
  def show(story, opts) do
    base = Keyword.fetch!(opts, :base_path)

    back = "[← Back to stories](#{base}/stories)\n\n"

    parts = [
      "# #{story.title}\n",
      "**ID:** #{story.id}",
      component_line(story),
      tags_line(story),
      status_line(story),
      "[View requirements](#{base}/stories/#{story.id}/requirements)"
    ]

    parts =
      if story.description && story.description != "" do
        parts ++ ["\n## Description\n\n#{story.description}"]
      else
        parts
      end

    parts = parts ++ [ac_section(story)]

    back <> (parts |> Enum.reject(&is_nil/1) |> Enum.join("\n")) <> "\n"
  end

  # -- Story summary (used in index) ------------------------------------------

  defp story_summary(story, base) do
    parts = ["## [#{story.title}](#{base}/stories/#{story.id}) (id: #{story.id})"]

    parts = parts ++ [component_line(story), tags_line(story)]

    parts =
      if story.description && story.description != "" do
        parts ++ ["\n#{story.description}"]
      else
        parts
      end

    parts = parts ++ [ac_section(story)]

    parts |> Enum.reject(&is_nil/1) |> Enum.join("\n")
  end

  # -- Shared helpers ----------------------------------------------------------

  defp component_line(story) do
    case story.component do
      %{module_name: name} -> "**Component:** `#{name}`"
      _ -> nil
    end
  end

  defp tags_line(story) do
    case story.tags do
      tags when is_list(tags) and tags != [] ->
        names = Enum.map_join(tags, ", ", & &1.name)
        "**Tags:** #{names}"

      _ ->
        nil
    end
  end

  defp status_line(story) do
    "**Status:** #{story.status || "unknown"} | **Priority:** #{story.priority || "—"}"
  end

  defp ac_section(story) do
    case story.acceptance_criteria do
      ac when is_list(ac) and ac != [] ->
        lines = Enum.map_join(ac, "\n", &"- [ ] #{&1}")
        "\n### Acceptance Criteria\n\n#{lines}"

      _ ->
        nil
    end
  end

  defp pagination_nav(_page, total_pages, _base) when total_pages <= 1, do: ""

  defp pagination_nav(page, total_pages, base) do
    prev =
      if page > 1,
        do: "[← Previous](#{base}/stories?page=#{page - 1})",
        else: nil

    next =
      if page < total_pages,
        do: "[Next →](#{base}/stories?page=#{page + 1})",
        else: nil

    links = [prev, next] |> Enum.reject(&is_nil/1) |> Enum.join(" | ")
    "\n\n---\n\n#{links}"
  end
end
