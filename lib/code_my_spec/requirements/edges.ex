defmodule CodeMySpec.Requirements.Edges do
  @moduledoc """
  The project's edge set: one topology, generated from records, shared by every
  checkout.

  Every edge is a function of one entity: a component's template and declared
  dependencies, a story's own chain, its kickoff into its components and the
  exits back, its joins to the project, and the project's own chain. No file
  moves an edge, so every checkout shares them; a checkout's edges are the ones
  whose two ends are rows there (`among/2`).

  Nothing here reduces. Readiness reads reachability, which a transitive
  reduction preserves, so a redundant edge changes no answer. A view that
  draws the graph reads the stored reduction. See knowledge/requirements_graph,
  "Edges".

  Requirement names appear here only as data read off the generated edges.
  """

  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Requirements.Topology
  alias CodeMySpec.Users.Scope

  @type edge :: Topology.edge()

  @doc """
  Every edge of the project's topology.

  `ctx` needs the shape and nothing more — `Preloader.topology_context/1` is
  enough — and its stories should be every ready story, wherever placed.
  """
  @spec generate(Scope.t(), map(), map()) :: [edge()]
  def generate(scope, ctx, config) do
    ctx = RequirementGraph.edge_context(ctx, config)

    [
      RequirementGraph.component_side_edges(ctx, config),
      RequirementGraph.project_side_edges(scope, config)
      | Enum.map(ctx.stories, &RequirementGraph.story_side_edges(&1, ctx, config))
    ]
    |> Enum.concat()
    |> Enum.uniq()
  end

  @doc "The edges whose two ends are among `keys`: one checkout's share."
  @spec among([edge()], MapSet.t(Topology.node_key())) :: [edge()]
  def among(edges, keys),
    do: Enum.filter(edges, &(MapSet.member?(keys, &1.from) and MapSet.member?(keys, &1.to)))
end
