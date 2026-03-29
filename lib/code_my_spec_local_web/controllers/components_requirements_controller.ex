defmodule CodeMySpecLocalWeb.ComponentsRequirementsController do
  @moduledoc """
  LLM API for component requirements status.
  """
  use CodeMySpecLocalWeb, :controller

  alias CodeMySpec.Components
  alias CodeMySpec.Files.RequirementGraph

  def index(conn, _params) do
    scope = conn.assigns.current_scope
    components = Components.list_components(scope)
    nodes = RequirementGraph.compute_all(scope)

    lines =
      Enum.map_join(components, "\n", fn component ->
        comp_nodes = Enum.filter(nodes, &(&1.entity_type == "component" and &1.entity_id == component.id))
        total = length(comp_nodes)
        satisfied = Enum.count(comp_nodes, & &1.satisfied)
        check = if satisfied == total and total > 0, do: "[x]", else: "[ ]"
        "- #{check} **#{component.module_name}** (#{satisfied}/#{total}) — type: #{component.type}, id: #{component.id}"
      end)

    text(conn, "# Components\n\n#{lines}\n")
  end

  def show(conn, %{"component_id" => component_id}) do
    scope = conn.assigns.current_scope
    component = Components.get_component!(scope, component_id)
    nodes = RequirementGraph.compute_all(scope)

    comp_nodes = Enum.filter(nodes, &(&1.entity_type == "component" and &1.entity_id == component.id))
    total = length(comp_nodes)
    satisfied = Enum.count(comp_nodes, & &1.satisfied)
    actionable_names = comp_nodes |> Enum.reject(& &1.satisfied) |> MapSet.new(& &1.name)

    lines =
      Enum.map_join(comp_nodes, "\n", fn n ->
        check = if n.satisfied, do: "[x]", else: "[ ]"
        tag = if MapSet.member?(actionable_names, n.name), do: " (actionable)", else: ""
        "- #{check} **#{n.name}** — #{n.description}#{tag}"
      end)

    text(conn, "# #{component.module_name} — Requirements (#{satisfied}/#{total})\n\nType: #{component.type}\n\n#{lines}\n")
  end

  def show_requirement(conn, %{"component_id" => component_id, "name" => name}) do
    scope = conn.assigns.current_scope
    nodes = RequirementGraph.compute_all(scope)

    node = Enum.find(nodes, fn n ->
      n.entity_type == "component" and n.entity_id == component_id and n.name == name
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
