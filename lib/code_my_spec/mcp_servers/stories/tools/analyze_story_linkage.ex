defmodule CodeMySpec.McpServers.Stories.Tools.AnalyzeStoryLinkage do
  @moduledoc """
  Analyze story-component linkage in the project.

  Returns a report showing unlinked stories, broken links, linked stories
  grouped by component, and orphan components with no stories.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Components
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Stories

  schema do
  end

  @impl true
  def execute(_params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame) do
      {:ok, stories} = Stories.list_project_stories(scope)
      components = Components.list_components(scope)

      markdown = analyze(stories, components)

      response =
        Response.tool()
        |> Response.text(markdown)

      {:reply, response, frame}
    else
      {:error, reason} ->
        response = Response.tool() |> Response.error(inspect(reason))
        {:reply, response, frame}
    end
  end

  defp analyze(stories, components) do
    component_ids = MapSet.new(components, & &1.id)
    component_map = Map.new(components, &{&1.id, &1})

    {unlinked, linked_or_broken} = Enum.split_with(stories, &is_nil(&1.component_id))

    {broken, linked} =
      Enum.split_with(linked_or_broken, fn story ->
        not MapSet.member?(component_ids, story.component_id)
      end)

    linked_by_component =
      linked
      |> Enum.group_by(& &1.component_id)
      |> Enum.map(fn {component_id, group_stories} ->
        {Map.fetch!(component_map, component_id), group_stories}
      end)
      |> Enum.sort_by(fn {component, _} -> component.module_name end)

    linked_component_ids = MapSet.new(linked, & &1.component_id)

    orphan_components =
      components
      |> Enum.reject(&MapSet.member?(linked_component_ids, &1.id))
      |> Enum.sort_by(& &1.module_name)

    render(unlinked, broken, linked_by_component, orphan_components, component_map)
  end

  defp render(unlinked, broken, linked_by_component, orphan_components, component_map) do
    sections =
      [
        render_unlinked(unlinked),
        render_broken(broken, component_map),
        render_linked(linked_by_component),
        render_orphans(orphan_components)
      ]
      |> Enum.reject(&is_nil/1)

    case sections do
      [] -> "All stories are linked. No orphan components.\n"
      _ -> Enum.join(sections, "\n")
    end
  end

  defp render_unlinked([]), do: nil

  defp render_unlinked(stories) do
    lines = Enum.map(stories, &"- #{&1.title}")
    "## Unlinked Stories\n\n#{Enum.join(lines, "\n")}\n"
  end

  defp render_broken([], _), do: nil

  defp render_broken(stories, component_map) do
    lines =
      Enum.map(stories, fn story ->
        component = Map.get(component_map, story.component_id)
        name = if component, do: component.module_name, else: "unknown"
        "- #{story.title} (references missing component: #{name})"
      end)

    "## Broken Links\n\n#{Enum.join(lines, "\n")}\n"
  end

  defp render_linked([]), do: nil

  defp render_linked(linked_by_component) do
    groups =
      Enum.map(linked_by_component, fn {component, stories} ->
        lines = Enum.map(stories, &"  - #{&1.title}")
        "- **#{component.module_name}**\n#{Enum.join(lines, "\n")}"
      end)

    "## Linked Stories\n\n#{Enum.join(groups, "\n")}\n"
  end

  defp render_orphans([]), do: nil

  defp render_orphans(components) do
    lines = Enum.map(components, &"- #{&1.module_name}")
    "## Orphan Components\n\n#{Enum.join(lines, "\n")}\n"
  end
end
