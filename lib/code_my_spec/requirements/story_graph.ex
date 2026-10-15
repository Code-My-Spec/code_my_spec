defmodule CodeMySpec.Requirements.StoryGraph do
  @moduledoc "A story's component architecture first, then its published requirements."

  alias CodeMySpec.{Components, Requirements, Stories}
  alias CodeMySpec.Requirements.RequirementGraph

  def read(scope, story_id) do
    case Stories.get_story(scope, story_id) do
      nil ->
        {:error, :not_found}

      story ->
        components = Components.list_components_with_dependencies(scope)
        graph = Requirements.cached_graph_with_actionable(scope)
        {:ok, project(story, components, graph)}
    end
  end

  def project(story, components, graph) do
    by_id = Map.new(components, &{&1.id, &1})

    ctx = %{
      components: components,
      components_by_id: by_id,
      children_by_parent: Enum.group_by(components, & &1.parent_component_id)
    }

    component_ids = RequirementGraph.story_component_ids(story, ctx)
    selected = Enum.filter(components, &MapSet.member?(component_ids, &1.id))

    # Ownership is presentation metadata, not an invitation to include a
    # parent's other children or count their requirements as story work.
    owners =
      selected
      |> Enum.flat_map(&parents(&1, by_id, MapSet.new()))
      |> Enum.uniq_by(& &1.id)
      |> Enum.reject(&MapSet.member?(component_ids, &1.id))

    component_edges =
      selected
      |> Enum.flat_map(fn component ->
        component.outgoing_dependencies
        |> Enum.filter(&MapSet.member?(component_ids, &1.target_component_id))
        |> Enum.map(
          &%{
            from: component.id,
            to: &1.target_component_id,
            provenance: &1.provenance,
            in_code: &1.in_code
          }
        )
      end)

    graph
    |> select(story.id, component_ids)
    |> Map.merge(%{
      story: story,
      root_component: by_id[story.component_id],
      component_ids: component_ids,
      components: selected,
      owners: owners,
      component_edges: component_edges
    })
  end

  def select(graph, story_id, component_ids) do
    roots =
      graph.nodes
      |> Enum.filter(fn node ->
        (node.entity_type == "story" and node.entity_id == story_id) or
          (node.entity_type == "issue" and node.details["story_id"] == story_id) or
          (node.entity_type == "component" and MapSet.member?(component_ids, node.entity_id))
      end)
      |> MapSet.new(&key/1)

    # Project prerequisites remain visible, but requirement edges cannot
    # widen the component architecture or pull in another story's kickoff.
    included = Enum.reduce(graph.edges, roots, &include_project_gate(&1, &2, roots))

    nodes = Enum.filter(graph.nodes, &MapSet.member?(included, key(&1)))
    keys = MapSet.new(nodes, &key/1)

    %{
      nodes: nodes,
      edges:
        Enum.filter(graph.edges, &(MapSet.member?(keys, &1.from) and MapSet.member?(keys, &1.to))),
      actionable: Enum.filter(graph.actionable, &MapSet.member?(keys, key(&1))),
      story_keys: roots
    }
  end

  @doc """
  Satisfied and total across the story's own slice — its requirements, its
  issues' and its components' — the non-boundary nodes the working copy status
  page draws. Project gates show there as context and are not counted.
  """
  @spec progress(map()) :: {non_neg_integer(), non_neg_integer()}
  def progress(%{nodes: nodes, story_keys: roots}) do
    owned = Enum.filter(nodes, &MapSet.member?(roots, key(&1)))
    {Enum.count(owned, & &1.satisfied), length(owned)}
  end

  defp include_project_gate(%{from: {"project", _, _} = from, to: to}, ids, roots) do
    if MapSet.member?(roots, to), do: MapSet.put(ids, from), else: ids
  end

  defp include_project_gate(_edge, ids, _roots), do: ids

  defp parents(component, by_id, seen) do
    parent = by_id[component.parent_component_id]

    if parent && not MapSet.member?(seen, parent.id),
      do: [parent | parents(parent, by_id, MapSet.put(seen, parent.id))],
      else: []
  end

  defp key(node), do: {node.entity_type, node.entity_id, node.name}
end
