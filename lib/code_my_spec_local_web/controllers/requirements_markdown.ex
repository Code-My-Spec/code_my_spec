defmodule CodeMySpecLocalWeb.RequirementsMarkdown do
  @moduledoc """
  Markdown rendering for requirements from computed graph nodes.
  """

  alias CodeMySpec.Requirements.RequirementDefinitionData

  def index(%{project: project, nodes: nodes, actionable: actionable}) do
    name = project.name || "Project"

    project_nodes = Enum.filter(nodes, &(&1.entity_type == "project"))
    total = length(project_nodes)
    satisfied = Enum.count(project_nodes, & &1.satisfied)

    # Sort by definition order
    definition_order =
      RequirementDefinitionData.project_requirements()
      |> Enum.with_index()
      |> Map.new(fn {defn, idx} -> {defn.name, idx} end)

    sorted = Enum.sort_by(project_nodes, fn n -> Map.get(definition_order, n.name, 999) end)

    actionable_names = MapSet.new(actionable, & &1.name)

    lines =
      Enum.map_join(sorted, "\n", fn n ->
        check = if n.satisfied, do: "[x]", else: "[ ]"
        tag = if MapSet.member?(actionable_names, n.name), do: " (actionable)", else: ""
        "- #{check} **#{n.name}** — #{n.description}#{tag}"
      end)

    "# #{name} — Requirements (#{satisfied}/#{total})\n\n#{lines}\n"
  end

  def show(%{node: node}) do
    status = if node.satisfied, do: "satisfied", else: "not satisfied"

    details =
      if node.details != %{} do
        "\n\n## Details\n\n```json\n#{Jason.encode!(node.details, pretty: true)}\n```"
      else
        ""
      end

    satisfied_by =
      if node.satisfied_by do
        task_name = node.satisfied_by |> inspect() |> String.split(".") |> List.last()
        "\n\nSatisfied by: `#{task_name}`"
      else
        ""
      end

    "# #{node.name}\n\n#{node.description}\n\nStatus: #{status}#{satisfied_by}#{details}\n"
  end
end
