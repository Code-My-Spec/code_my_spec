defmodule CodeMySpecLocalWeb.StoriesRequirementsController do
  @moduledoc """
  LLM API for story requirements status.
  """
  use CodeMySpecLocalWeb, :controller

  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Stories

  def index(conn, _params) do
    scope = conn.assigns.current_scope
    nodes = RequirementGraph.compute_all(scope)

    case Stories.list_project_stories(scope) do
      {:ok, stories} ->
        lines =
          Enum.map_join(stories, "\n", fn story ->
            story_nodes = Enum.filter(nodes, &(&1.entity_type == "story" and &1.entity_id == story.id))
            total = length(story_nodes)
            satisfied = Enum.count(story_nodes, & &1.satisfied)
            check = if satisfied == total and total > 0, do: "[x]", else: "[ ]"
            "- #{check} **#{story.title}** (#{satisfied}/#{total}) — id: #{story.id}"
          end)

        text(conn, "# Stories\n\n#{lines}\n")

      _ ->
        text(conn, "# Stories\n\nNo stories found.\n")
    end
  end

  def show(conn, %{"story_id" => story_id, "project_name" => project_name}) do
    scope = conn.assigns.current_scope
    nodes = RequirementGraph.compute_all(scope)

    case Stories.get_story(scope, story_id) do
      story when not is_nil(story) ->
        story_nodes = Enum.filter(nodes, &(&1.entity_type == "story" and &1.entity_id == story.id))
        total = length(story_nodes)
        satisfied = Enum.count(story_nodes, & &1.satisfied)
        actionable_names = story_nodes |> Enum.reject(& &1.satisfied) |> MapSet.new(& &1.name)

        lines =
          Enum.map_join(story_nodes, "\n", fn n ->
            check = if n.satisfied, do: "[x]", else: "[ ]"
            tag = if MapSet.member?(actionable_names, n.name), do: " (actionable)", else: ""
            "- #{check} **#{n.name}** — #{n.description}#{tag}"
          end)

        component_info =
          if story.component_id do
            "\n\nLinked component: #{story.component_id}"
          else
            "\n\nNo component linked."
          end

        story_detail = "Story detail: /api/projects/#{project_name}/stories/#{story_id}"

        text(conn, "# #{story.title} — Requirements (#{satisfied}/#{total})\n\n#{lines}#{component_info}\n\n#{story_detail}\n")

      nil ->
        conn |> put_status(404) |> text("Story not found: #{story_id}")
    end
  end

  def show_requirement(conn, %{"story_id" => story_id, "name" => name}) do
    scope = conn.assigns.current_scope
    nodes = RequirementGraph.compute_all(scope)

    story_id_int = String.to_integer(story_id)

    node = Enum.find(nodes, fn n ->
      n.entity_type == "story" and n.entity_id == story_id_int and n.name == name
    end)

    if node do
      text(conn, render_node(node, scope))
    else
      conn |> put_status(404) |> text("Requirement not found: #{name}")
    end
  end

  defp render_node(node, scope) do
    status = if node.satisfied, do: "satisfied", else: "not satisfied"

    prompt =
      if node.satisfied_by && !node.satisfied do
        case node.satisfied_by.command(scope, %{}) do
          {:ok, text} -> "\n\n## Prompt\n\n#{text}"
          _ -> ""
        end
      else
        ""
      end

    "# #{node.name}\n\n#{node.description}\n\nStatus: #{status}#{prompt}\n"
  end
end
