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
  alias CodeMySpec.Tags
  alias Hermes.Server.Response

  schema do
    field :app_name, :string, doc: "Application name for suggested context naming"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_project_scope(frame) do
      stories = Stories.list_project_stories(scope)
      all_tags = Tags.list_project_tags(scope)

      if stories == [] do
        {:reply, ArchitectureMapper.error("No stories found. Import stories first using the stories tools."), frame}
      else
        app_name = params[:app_name] || derive_app_name(scope)
        analysis = analyze_by_tags(scope, stories, all_tags, app_name)
        response = format_analysis_response(analysis)
        {:reply, response, frame}
      end
    else
      {:error, reason} ->
        {:reply, ArchitectureMapper.error(reason), frame}
    end
  end

  defp analyze_by_tags(scope, stories, all_tags, app_name) do
    # Build a map of story_id -> tags
    story_tags_map =
      stories
      |> Enum.map(fn story ->
        tags = Tags.list_story_tags(scope, story)
        {story.id, tags}
      end)
      |> Map.new()

    # Group stories by each tag
    tag_groupings =
      all_tags
      |> Enum.map(fn tag ->
        stories_with_tag =
          stories
          |> Enum.filter(fn story ->
            story_tags = Map.get(story_tags_map, story.id, [])
            Enum.any?(story_tags, &(&1.id == tag.id))
          end)

        %{
          tag: tag.name,
          story_count: length(stories_with_tag),
          stories: Enum.map(stories_with_tag, fn s ->
            %{id: s.id, title: s.title}
          end)
        }
      end)
      |> Enum.filter(&(&1.story_count > 0))
      |> Enum.sort_by(& &1.story_count, :desc)

    # Find untagged stories
    untagged_stories =
      stories
      |> Enum.filter(fn story ->
        story_tags = Map.get(story_tags_map, story.id, [])
        Enum.empty?(story_tags)
      end)
      |> Enum.map(fn s -> %{id: s.id, title: s.title} end)

    # Suggest contexts based on tags with 3+ stories
    suggested_contexts =
      tag_groupings
      |> Enum.filter(&(&1.story_count >= 3))
      |> Enum.map(fn grouping ->
        context_name = build_context_name(app_name, grouping.tag)
        %{
          name: context_name,
          tag: grouping.tag,
          story_count: grouping.story_count,
          story_ids: Enum.map(grouping.stories, & &1.id)
        }
      end)

    %{
      total_stories: length(stories),
      tagged_stories: length(stories) - length(untagged_stories),
      untagged_stories: untagged_stories,
      tag_groupings: tag_groupings,
      suggested_contexts: suggested_contexts,
      app_name: app_name
    }
  end

  defp format_analysis_response(analysis) do
    markdown = """
    ## Story Analysis by Tags

    **Total Stories:** #{analysis.total_stories}
    **Tagged:** #{analysis.tagged_stories}
    **Untagged:** #{length(analysis.untagged_stories)}

    #{format_tag_groupings(analysis.tag_groupings)}

    #{format_suggested_contexts(analysis.suggested_contexts, analysis.app_name)}

    #{format_untagged_stories(analysis.untagged_stories)}

    ---

    Data: #{Jason.encode!(analysis)}
    """

    Response.tool()
    |> Response.text(String.trim(markdown))
  end

  defp format_tag_groupings([]) do
    """
    ### Tag Groupings

    No tags found. Use `add_story_tag` or `tag_stories` to organize stories by domain first:

    1. Review your stories with `list_stories` or `get_story`
    2. Identify domain themes (e.g., "accounts", "notifications", "fraud-detection")
    3. Tag stories with `tag_stories` or `add_story_tag`
    4. Run `analyze_stories` again to see groupings
    """
  end

  defp format_tag_groupings(groupings) do
    lines =
      groupings
      |> Enum.map(fn g ->
        story_ids = Enum.map(g.stories, & &1.id) |> Enum.join(", ")
        "- **#{g.tag}** (#{g.story_count} stories): IDs #{story_ids}"
      end)
      |> Enum.join("\n")

    """
    ### Tag Groupings

    #{lines}
    """
  end

  defp format_suggested_contexts([], _app_name) do
    """
    ### Suggested Bounded Contexts

    No contexts suggested yet. Tag at least 3 stories with the same tag to get context suggestions.
    """
  end

  defp format_suggested_contexts(contexts, _app_name) do
    lines =
      contexts
      |> Enum.with_index(1)
      |> Enum.map(fn {ctx, idx} ->
        "#{idx}. **#{ctx.name}** (from tag '#{ctx.tag}') - #{ctx.story_count} stories"
      end)
      |> Enum.join("\n")

    """
    ### Suggested Bounded Contexts

    Based on tags with 3+ stories:

    #{lines}

    Use `propose_architecture` with these contexts to create the component structure.
    """
  end

  defp format_untagged_stories([]), do: ""

  defp format_untagged_stories(untagged) do
    lines =
      untagged
      |> Enum.take(10)
      |> Enum.map(fn s -> "- #{s.title} (ID: #{s.id})" end)
      |> Enum.join("\n")

    more = if length(untagged) > 10, do: "\n... and #{length(untagged) - 10} more", else: ""

    """
    ### Untagged Stories

    These stories need to be categorized:

    #{lines}#{more}

    Use `tag_stories` with the story IDs and appropriate domain tags.
    """
  end

  defp build_context_name(app_name, tag) do
    # Handle component: prefix tags
    tag_part =
      tag
      |> String.replace_prefix("component:", "")
      |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
      |> String.split("_")
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&String.capitalize/1)
      |> Enum.join()

    "#{app_name}.#{tag_part}"
  end

  defp derive_app_name(scope) do
    scope.active_project.name
    |> String.replace(~r/[^a-zA-Z0-9]/, "")
    |> Macro.camelize()
  end
end
