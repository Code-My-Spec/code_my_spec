defmodule CodeMySpec.McpServers.Architecture.Tools.AnalyzeStories do
  @moduledoc """
  MCP tool for analyzing user stories grouped by tags.

  Stories should be tagged first using add_story_tag or tag_stories tools.
  This tool then groups stories by their tags to inform architecture design.

  Returns a structured view of stories organized by domain/feature tags.
  """

  use Hermes.Server.Component, type: :tool
  require Logger

  alias CodeMySpec.McpServers.Architecture.ArchitectureMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Stories
  alias Hermes.Server.Response

  schema do
  end

  @impl true
  def execute(_params, frame) do
    with {:ok, scope} <- Validators.validate_project_scope(frame),
         {:ok, stories} <- Stories.list_project_stories(scope) do
      if stories == [] do
        {:reply, ArchitectureMapper.error("No stories found. Import stories first using the stories tools."), frame}
      else
        analysis = analyze_stories(stories)
        response = format_response(analysis)
        {:reply, response, frame}
      end
    else
      {:error, :authentication_failed} ->
        {:reply, ArchitectureMapper.error("Authentication failed. Please run 'codemyspec auth login' to re-authenticate."), frame}

      {:error, :needs_authentication} ->
        {:reply, ArchitectureMapper.error("Authentication required. Please run 'codemyspec auth login' to authenticate."), frame}

      {:error, reason} ->
        {:reply, ArchitectureMapper.error("Failed to fetch data: #{inspect(reason)}"), frame}

      other ->
        Logger.error("analyze_stories unexpected result: #{inspect(other)}")
        {:reply, ArchitectureMapper.error("Unexpected result: #{inspect(other)}"), frame}
    end
  end

  defp analyze_stories(stories) do
    all_tags = extract_all_tags(stories)
    tag_groupings = build_tag_groupings(stories, all_tags)
    untagged = find_untagged_stories(stories)
    co_occurrences = find_tag_co_occurrences(stories, all_tags)

    %{
      total_stories: length(stories),
      tagged_count: length(stories) - length(untagged),
      untagged_count: length(untagged),
      tag_groupings: tag_groupings,
      untagged_stories: untagged,
      co_occurrences: co_occurrences
    }
  end

  defp extract_all_tags(stories) do
    stories
    |> Enum.flat_map(fn story -> story.tags || [] end)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.name)
  end

  defp build_tag_groupings(stories, all_tags) do
    all_tags
    |> Enum.map(fn tag ->
      matching_stories =
        stories
        |> Enum.filter(fn story ->
          story_tags = story.tags || []
          Enum.any?(story_tags, &(&1.id == tag.id))
        end)

      %{
        tag: tag.name,
        story_count: length(matching_stories),
        stories: Enum.map(matching_stories, &%{id: &1.id, title: &1.title})
      }
    end)
    |> Enum.filter(&(&1.story_count > 0))
    |> Enum.sort_by(& &1.story_count, :desc)
  end

  defp find_untagged_stories(stories) do
    stories
    |> Enum.filter(fn story ->
      tags = story.tags || []
      Enum.empty?(tags)
    end)
    |> Enum.map(&%{id: &1.id, title: &1.title})
  end

  defp find_tag_co_occurrences(stories, all_tags) do
    # Build pairs of tags that appear together on stories
    tag_names = Enum.map(all_tags, & &1.name)

    stories
    |> Enum.flat_map(fn story ->
      story_tag_names =
        (story.tags || [])
        |> Enum.map(& &1.name)
        |> Enum.filter(&(&1 in tag_names))

      # Generate all pairs for this story
      for t1 <- story_tag_names, t2 <- story_tag_names, t1 < t2 do
        {t1, t2}
      end
    end)
    |> Enum.frequencies()
    |> Enum.map(fn {{t1, t2}, count} -> %{tags: [t1, t2], count: count} end)
    |> Enum.filter(&(&1.count >= 2))
    |> Enum.sort_by(& &1.count, :desc)
    |> Enum.take(15)
  end

  defp format_response(analysis) do
    markdown = """
    ## Story Analysis

    **Total:** #{analysis.total_stories} | **Tagged:** #{analysis.tagged_count} | **Untagged:** #{analysis.untagged_count}

    #{format_tag_groupings(analysis.tag_groupings)}
    #{format_co_occurrences(analysis.co_occurrences)}
    #{format_untagged(analysis.untagged_stories)}
    """

    Response.tool()
    |> Response.text(String.trim(markdown))
  end

  defp format_tag_groupings([]) do
    """
    ### Tags

    No tags found. Tag stories first using `tag_stories` or `add_story_tag`.
    """
  end

  defp format_tag_groupings(groupings) do
    # Check if tags have prefixes (contain ":")
    has_prefixes = Enum.any?(groupings, fn g -> String.contains?(g.tag, ":") end)

    content =
      if has_prefixes do
        format_grouped_by_prefix(groupings)
      else
        format_flat_tags(groupings)
      end

    """
    ### Tags

    #{content}
    """
  end

  defp format_flat_tags(groupings) do
    groupings
    |> Enum.map(fn g ->
      ids = g.stories |> Enum.map(& &1.id) |> Enum.join(", ")
      "- **#{g.tag}** (#{g.story_count}): #{ids}"
    end)
    |> Enum.join("\n")
  end

  defp format_grouped_by_prefix(groupings) do
    # Group by prefix, with unprefixed tags in their own group
    grouped =
      groupings
      |> Enum.group_by(fn g ->
        case String.split(g.tag, ":", parts: 2) do
          [prefix, _rest] -> prefix
          [_no_prefix] -> "_other"
        end
      end)
      |> Enum.sort_by(fn {prefix, _} -> if prefix == "_other", do: "zzz", else: prefix end)

    grouped
    |> Enum.map(fn {prefix, tags} ->
      prefix_label = if prefix == "_other", do: "Other", else: String.capitalize(prefix)

      tag_lines =
        tags
        |> Enum.map(fn g ->
          # Strip prefix for display if grouped
          display_name =
            case String.split(g.tag, ":", parts: 2) do
              [_prefix, rest] -> rest
              [name] -> name
            end

          ids = g.stories |> Enum.map(& &1.id) |> Enum.join(", ")
          "  - #{display_name} (#{g.story_count}): #{ids}"
        end)
        |> Enum.join("\n")

      "**#{prefix_label}**\n#{tag_lines}"
    end)
    |> Enum.join("\n\n")
  end

  defp format_co_occurrences([]), do: ""

  defp format_co_occurrences(co_occurrences) do
    lines =
      co_occurrences
      |> Enum.map(fn %{tags: [t1, t2], count: count} ->
        "- #{t1} + #{t2} (#{count} stories)"
      end)
      |> Enum.join("\n")

    """

    ### Tag Co-occurrence

    #{lines}
    """
  end

  defp format_untagged([]), do: ""

  defp format_untagged(untagged) do
    lines =
      untagged
      |> Enum.take(10)
      |> Enum.map(fn s -> "- [#{s.id}] #{s.title}" end)
      |> Enum.join("\n")

    more = if length(untagged) > 10, do: "\n_...and #{length(untagged) - 10} more_", else: ""

    """

    ### Untagged Stories

    #{lines}#{more}
    """
  end
end
