defmodule CodeMySpec.Requirements.GraphProjector do
  @moduledoc """
  Projects the computed requirement graph into a Mermaid flowchart string.

  Reads from RequirementGraph.compute_all — no persisted requirements needed.

  Nodes are colored by satisfaction status:
  - satisfied → blue
  - actionable (unsatisfied, all prereqs met) → green
  - blocked (unsatisfied, prereqs not met) → amber

  Edges show prerequisite relationships within the same entity.
  Requirements are grouped into subgraphs by entity (project, story, component).
  """

  alias CodeMySpec.Files.RequirementGraph
  alias CodeMySpec.Users.Scope

  @spec project_graph(Scope.t()) :: String.t()
  def project_graph(%Scope{} = scope) do
    nodes = RequirementGraph.compute_all(scope)
    build_mermaid(nodes)
  end

  defp build_mermaid([]) do
    "flowchart TD\n  empty[No requirements]"
  end

  defp build_mermaid(nodes) do
    # Build satisfaction map for actionable detection
    satisfaction_map =
      Map.new(nodes, fn n ->
        {{n.entity_type, n.entity_id, n.name}, n.satisfied}
      end)

    # Group by entity
    project_nodes = Enum.filter(nodes, &(&1.entity_type == "project"))

    story_groups =
      nodes
      |> Enum.filter(&(&1.entity_type == "story"))
      |> Enum.group_by(& &1.entity_id)
      |> Enum.sort_by(fn {_id, [n | _]} -> n.entity_name end)

    component_groups =
      nodes
      |> Enum.filter(&(&1.entity_type == "component"))
      |> Enum.group_by(& &1.entity_id)
      |> Enum.sort_by(fn {_id, [n | _]} -> n.entity_name end)

    lines = ["flowchart TD"]

    # Project subgraph
    lines =
      if project_nodes != [] do
        lines ++ render_subgraph("project", "Project", project_nodes, satisfaction_map)
      else
        lines
      end

    # Story subgraphs
    lines =
      Enum.reduce(story_groups, lines, fn {story_id, story_nodes}, acc ->
        title = hd(story_nodes).entity_name
        subgraph_id = "story_#{story_id}"
        acc ++ render_subgraph(subgraph_id, "Story: #{truncate(title, 40)}", story_nodes, satisfaction_map)
      end)

    # Component subgraphs
    lines =
      Enum.reduce(component_groups, lines, fn {comp_id, comp_nodes}, acc ->
        module_name = hd(comp_nodes).entity_name
        subgraph_id = sanitize_id(comp_id)
        acc ++ render_subgraph(subgraph_id, short_module(module_name), comp_nodes, satisfaction_map)
      end)

    # Render edges from prerequisites (within same entity)
    edge_lines =
      nodes
      |> Enum.flat_map(fn node ->
        target_id = node_id(node)

        (node.prerequisites || [])
        |> Enum.map(fn prereq_name ->
          source_id = "#{type_prefix(node.entity_type)}_#{sanitize_id(node.entity_id)}_#{prereq_name}"
          "  #{source_id} --> #{target_id}"
        end)
      end)
      |> Enum.uniq()

    class_defs = [
      "  classDef satisfied fill:#60a5fa,stroke:#2563eb,color:#000",
      "  classDef actionable fill:#4ade80,stroke:#16a34a,color:#000",
      "  classDef blocked fill:#fbbf24,stroke:#d97706,color:#000"
    ]

    (lines ++ edge_lines ++ class_defs)
    |> Enum.join("\n")
  end

  defp render_subgraph(subgraph_id, label, nodes, satisfaction_map) do
    header = ["  subgraph #{subgraph_id}[\"#{escape_mermaid(label)}\"]"]

    node_lines =
      Enum.map(nodes, fn node ->
        id = node_id(node)
        status_class = status_class(node, satisfaction_map)
        "    #{id}[\"#{escape_mermaid(node.name)}\"]:::#{status_class}"
      end)

    footer = ["  end"]
    header ++ node_lines ++ footer
  end

  defp status_class(%{satisfied: true}, _), do: "satisfied"

  defp status_class(node, satisfaction_map) do
    deps_met =
      (node.prerequisites || [])
      |> Enum.all?(fn prereq_name ->
        key = {node.entity_type, node.entity_id, prereq_name}
        Map.get(satisfaction_map, key, true)
      end)

    if deps_met, do: "actionable", else: "blocked"
  end

  defp node_id(node) do
    "#{type_prefix(node.entity_type)}_#{sanitize_id(node.entity_id)}_#{node.name}"
  end

  defp type_prefix("component"), do: "c"
  defp type_prefix("story"), do: "s"
  defp type_prefix("project"), do: "p"

  defp sanitize_id(id) when is_binary(id), do: String.replace(id, "-", "")
  defp sanitize_id(id) when is_integer(id), do: "#{id}"

  defp short_module(module_name) when is_binary(module_name) do
    parts = String.split(module_name, ".")

    case length(parts) do
      n when n <= 2 -> module_name
      _ -> Enum.drop(parts, 1) |> Enum.join(".")
    end
  end

  defp short_module(nil), do: "Unknown"

  defp truncate(str, max) when byte_size(str) > max do
    String.slice(str, 0, max) <> "..."
  end

  defp truncate(str, _max), do: str

  defp escape_mermaid(str) do
    str
    |> String.replace("\"", "#quot;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
