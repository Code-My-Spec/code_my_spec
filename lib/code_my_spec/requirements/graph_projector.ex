defmodule CodeMySpec.Requirements.GraphProjector do
  @moduledoc """
  Projects the requirements graph into a Mermaid flowchart string.

  Nodes are colored by satisfaction status:
  - satisfied → blue
  - actionable (unsatisfied, all deps met) → green
  - blocked (unsatisfied, deps not met) → amber

  Edges show dependency relationships (requirement → depends_on).
  Requirements are grouped into subgraphs by entity (project, story, component).
  """

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Requirements.Requirement
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  import Ecto.Query

  @spec project_graph(Scope.t()) :: String.t()
  def project_graph(%Scope{active_project_id: project_id} = _scope) do
    requirements = load_all_requirements(project_id)
    components = load_components(project_id)
    stories = load_stories(project_id)

    build_mermaid(requirements, components, stories, project_id)
  end

  defp load_all_requirements(project_id) do
    component_ids =
      from(c in Component,
        where: c.project_id == ^project_id,
        select: c.id
      )

    story_ids =
      from(s in Story,
        where: s.project_id == ^project_id,
        select: s.id
      )

    from(r in Requirement,
      where:
        r.component_id in subquery(component_ids) or
          r.story_id in subquery(story_ids) or
          r.project_id == ^project_id,
      order_by: [asc: r.name]
    )
    |> Repo.all()
  end

  defp load_components(project_id) do
    from(c in Component,
      where: c.project_id == ^project_id,
      select: {c.id, c.module_name, c.type}
    )
    |> Repo.all()
    |> Map.new(fn {id, name, type} -> {id, %{module_name: name, type: type}} end)
  end

  defp load_stories(project_id) do
    from(s in Story,
      where: s.project_id == ^project_id,
      select: {s.id, s.title}
    )
    |> Repo.all()
    |> Map.new(fn {id, title} -> {id, title} end)
  end

  defp build_mermaid([], _components, _stories, _project_id) do
    "flowchart TD\n  empty[No requirements]"
  end

  defp build_mermaid(requirements, components, stories, _project_id) do
    # Build satisfaction map for actionable detection
    satisfaction_map =
      Map.new(requirements, fn r ->
        {{entity_type(r), entity_id(r), r.name}, r.satisfied}
      end)

    # Group by entity
    {project_reqs, entity_reqs} =
      Enum.split_with(requirements, fn r -> not is_nil(r.project_id) end)

    {story_reqs, component_reqs} =
      Enum.split_with(entity_reqs, fn r -> not is_nil(r.story_id) end)

    component_groups =
      component_reqs
      |> Enum.group_by(& &1.component_id)
      |> Enum.sort_by(fn {comp_id, _} ->
        case Map.get(components, comp_id) do
          nil -> ""
          comp -> comp.module_name
        end
      end)

    story_groups =
      story_reqs
      |> Enum.group_by(& &1.story_id)
      |> Enum.sort_by(fn {story_id, _} ->
        Map.get(stories, story_id, "Story #{story_id}")
      end)

    lines = ["flowchart TD"]

    # Project subgraph
    lines =
      if project_reqs != [] do
        lines ++ render_subgraph("project", "Project", project_reqs, satisfaction_map)
      else
        lines
      end

    # Story subgraphs
    lines =
      Enum.reduce(story_groups, lines, fn {story_id, reqs}, acc ->
        title = Map.get(stories, story_id, "Story #{story_id}")
        subgraph_id = "story_#{story_id}"
        acc ++ render_subgraph(subgraph_id, "Story: #{truncate(title, 40)}", reqs, satisfaction_map)
      end)

    # Component subgraphs
    lines =
      Enum.reduce(component_groups, lines, fn {comp_id, reqs}, acc ->
        comp = Map.get(components, comp_id, %{module_name: "Unknown", type: "?"})
        subgraph_id = sanitize_id(comp_id)
        label = "#{short_module(comp.module_name)} (#{comp.type})"
        acc ++ render_subgraph(subgraph_id, label, reqs, satisfaction_map)
      end)

    # Render edges from depends_on
    edge_lines =
      requirements
      |> Enum.flat_map(fn req ->
        target_id = node_id(req)

        (req.depends_on || [])
        |> Enum.map(fn edge ->
          source_id = edge_node_id(edge)
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

  defp render_subgraph(subgraph_id, label, requirements, satisfaction_map) do
    header = ["  subgraph #{subgraph_id}[\"#{escape_mermaid(label)}\"]"]

    nodes =
      Enum.map(requirements, fn req ->
        id = node_id(req)
        status_class = status_class(req, satisfaction_map)
        "    #{id}[\"#{escape_mermaid(req.name)}\"]:::#{status_class}"
      end)

    footer = ["  end"]
    header ++ nodes ++ footer
  end

  defp status_class(%Requirement{satisfied: true}, _), do: "satisfied"

  defp status_class(%Requirement{} = req, satisfaction_map) do
    deps_met =
      (req.depends_on || [])
      |> Enum.all?(fn edge ->
        key = {edge["entity_type"], edge["entity_id"], edge["requirement_name"]}
        Map.get(satisfaction_map, key, true)
      end)

    if deps_met, do: "actionable", else: "blocked"
  end

  defp node_id(%Requirement{} = req) do
    case {req.component_id, req.story_id, req.project_id} do
      {id, _, _} when not is_nil(id) -> "c_#{sanitize_id(id)}_#{req.name}"
      {_, id, _} when not is_nil(id) -> "s_#{id}_#{req.name}"
      {_, _, id} when not is_nil(id) -> "p_#{sanitize_id(id)}_#{req.name}"
    end
  end

  defp edge_node_id(%{"entity_type" => "component", "entity_id" => id, "requirement_name" => name}) do
    "c_#{sanitize_id(id)}_#{name}"
  end

  defp edge_node_id(%{"entity_type" => "story", "entity_id" => id, "requirement_name" => name}) do
    "s_#{id}_#{name}"
  end

  defp edge_node_id(%{"entity_type" => "project", "entity_id" => id, "requirement_name" => name}) do
    "p_#{sanitize_id(id)}_#{name}"
  end

  defp entity_type(%Requirement{component_id: id}) when not is_nil(id), do: "component"
  defp entity_type(%Requirement{story_id: id}) when not is_nil(id), do: "story"
  defp entity_type(%Requirement{project_id: id}) when not is_nil(id), do: "project"

  defp entity_id(%Requirement{component_id: id}) when not is_nil(id), do: id
  defp entity_id(%Requirement{story_id: id}) when not is_nil(id), do: id
  defp entity_id(%Requirement{project_id: id}) when not is_nil(id), do: id

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
