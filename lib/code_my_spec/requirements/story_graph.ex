defmodule CodeMySpec.Requirements.StoryGraph do
  @moduledoc "A story's component architecture first, then its published requirements."

  alias CodeMySpec.{Components, Issues, Requirements, Stories}
  alias CodeMySpec.Requirements.{CopyGraph, Projection, RequirementGraph, Topology}
  alias CodeMySpec.Users.Scope

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

  @doc """
  `progress/1` of the story's slice, reading only the slice's stored rows: the
  story's, its issues' and its components'. `read/2` serves the whole graph
  and its actionable set before selecting, which a count needs neither of.
  Settles first, like every read, so a story whose rows are pending is not
  read as having none.
  """
  @spec read_progress(Scope.t(), integer()) ::
          {:ok, {non_neg_integer(), non_neg_integer()}} | {:error, :not_found}
  def read_progress(scope, story_id) do
    case Stories.get_story(scope, story_id) do
      nil ->
        {:error, :not_found}

      story ->
        ctx = component_context(Components.list_components_with_dependencies(scope))
        component_ids = RequirementGraph.story_component_ids(story, ctx)

        slice =
          Map.merge(ctx, %{
            components: Enum.filter(ctx.components, &MapSet.member?(component_ids, &1.id)),
            stories: [story],
            story_issues: Issues.list_story_submissions(scope, story.id)
          })

        vantage = %{scope | active_working_copy_id: Projection.vantage(scope)}
        :ok = RequirementGraph.settle(vantage)
        {nodes, _edges} = CopyGraph.load(vantage, slice)
        owned = Enum.filter(nodes, &root?(&1, story.id, component_ids))

        {:ok, {Enum.count(owned, & &1.satisfied), length(owned)}}
    end
  end

  def project(story, components, graph) do
    ctx = component_context(components)
    by_id = ctx.components_by_id

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
      |> Enum.filter(&root?(&1, story_id, component_ids))
      |> MapSet.new(&key/1)

    # Project prerequisites remain visible, but requirement edges cannot
    # widen the component architecture or pull in another story's kickoff.
    included = Enum.reduce(graph.edges, roots, &include_project_gate(&1, &2, roots))

    nodes = Enum.filter(graph.nodes, &MapSet.member?(included, key(&1)))
    keys = MapSet.new(nodes, &key/1)

    # Drawn reduced over the slice: rows hold every edge as generated.
    edges =
      graph.edges
      |> Enum.filter(&(MapSet.member?(keys, &1.from) and MapSet.member?(keys, &1.to)))
      |> Topology.transitive_reduction()

    %{
      nodes: nodes,
      edges: edges,
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

  defp component_context(components) do
    %{
      components: components,
      components_by_id: Map.new(components, &{&1.id, &1}),
      children_by_parent: Enum.group_by(components, & &1.parent_component_id)
    }
  end

  # The story's own nodes: what its slice counts, before project gates join.
  defp root?(node, story_id, component_ids) do
    (node.entity_type == "story" and node.entity_id == story_id) or
      (node.entity_type == "issue" and node.details["story_id"] == story_id) or
      (node.entity_type == "component" and MapSet.member?(component_ids, node.entity_id))
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
