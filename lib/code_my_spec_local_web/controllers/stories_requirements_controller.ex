defmodule CodeMySpecLocalWeb.StoriesRequirementsController do
  @moduledoc """
  LLM API for story requirements status.
  """
  use CodeMySpecLocalWeb, :controller

  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Stories

  def index(conn, _params) do
    scope = conn.assigns.current_scope
    # The rows. These are read surfaces — a markdown listing for a person or an
    # agent — and recomputing the whole project to render one is the behaviour
    # this whole change removes: it hides a writer that announced nothing by
    # repairing the graph on the way past, and costs seconds on the way.
    {nodes, _computed_at} = Requirements.cached_all(scope)

    case Stories.list_project_stories(scope) do
      {:ok, stories} ->
        lines = Enum.map_join(stories, "\n", &index_story_line(&1, nodes))
        text(conn, "# Stories\n\n#{lines}\n")

      _ ->
        text(conn, "# Stories\n\nNo stories found.\n")
    end
  end

  defp index_story_line(story, nodes) do
    story_nodes = Enum.filter(nodes, &(&1.entity_type == "story" and &1.entity_id == story.id))
    total = length(story_nodes)
    satisfied = Enum.count(story_nodes, & &1.satisfied)
    check = if satisfied == total and total > 0, do: "[x]", else: "[ ]"
    "- #{check} **#{story.title}** (#{satisfied}/#{total}) — id: #{story.id}"
  end

  def show(conn, %{"story_id" => story_id, "project_name" => project_name}) do
    scope = conn.assigns.current_scope

    # Nodes and the actionable set from one pass, because "(actionable)" is a
    # claim about edges, not about a node on its own. Tagging every unsatisfied
    # node read `deploy (actionable)` while its `qa_complete` prerequisite was
    # still open — the real loop never offered it, but anything reading this
    # listing was told otherwise.
    # The rows. These are read surfaces — a markdown listing for a person or an
    # agent — and recomputing the whole project to render one is the behaviour
    # this whole change removes: it hides a writer that announced nothing by
    # repairing the graph on the way past, and costs seconds on the way.
    {{nodes, _edges}, actionable, _computed_at} =
      RequirementGraph.cached_graph_with_actionable(scope)

    case Stories.get_story(scope, story_id) do
      story when not is_nil(story) ->
        render_story_show(conn, story, nodes, actionable, project_name, story_id)

      nil ->
        conn |> put_status(404) |> text("Story not found: #{story_id}")
    end
  end

  defp render_story_show(conn, story, nodes, actionable, project_name, story_id) do
    story_nodes = Enum.filter(nodes, &(&1.entity_type == "story" and &1.entity_id == story.id))
    total = length(story_nodes)
    satisfied = Enum.count(story_nodes, & &1.satisfied)

    actionable_names =
      actionable
      |> Enum.filter(&(&1.entity_type == "story" and &1.entity_id == story.id))
      |> MapSet.new(& &1.name)

    lines = Enum.map_join(story_nodes, "\n", &story_node_line(&1, actionable_names))
    component_info = component_info_line(story.component_id)
    story_detail = "Story detail: /api/projects/#{project_name}/stories/#{story_id}"

    text(
      conn,
      "# #{story.title} — Requirements (#{satisfied}/#{total})\n\n#{lines}#{component_info}\n\n#{story_detail}\n"
    )
  end

  defp story_node_line(n, actionable_names) do
    check = if n.satisfied, do: "[x]", else: "[ ]"
    tag = if MapSet.member?(actionable_names, n.name), do: " (actionable)", else: ""
    "- #{check} **#{n.name}** — #{n.description}#{tag}"
  end

  defp component_info_line(nil), do: "\n\nNo component linked."
  defp component_info_line(component_id), do: "\n\nLinked component: #{component_id}"

  def show_requirement(conn, %{"story_id" => story_id, "name" => name}) do
    scope = conn.assigns.current_scope
    # The rows. These are read surfaces — a markdown listing for a person or an
    # agent — and recomputing the whole project to render one is the behaviour
    # this whole change removes: it hides a writer that announced nothing by
    # repairing the graph on the way past, and costs seconds on the way.
    {nodes, _computed_at} = Requirements.cached_all(scope)

    story_id_int = String.to_integer(story_id)

    node =
      Enum.find(nodes, fn n ->
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
