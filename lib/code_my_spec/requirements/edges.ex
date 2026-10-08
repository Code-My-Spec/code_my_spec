defmodule CodeMySpec.Requirements.Edges do
  @moduledoc """
  The edge set, derived one entity at a time.

  `RequirementGraph.compute_edges/3` draws every edge of a vantage and reduces
  the whole set at once, on the grounds that a transitive reduction is global:
  a node instantiated for one entity can make an edge between two others
  redundant. True — and it made a component appearing cost a reduction over
  twenty-five thousand edges at every vantage: 355ms of a 430ms edge phase,
  ten vantages, for one event (measured 2026-09-21).

  It is also more general than this graph. Three facts about the templates
  bound where a path can go:

    * the project enters a story at one end and the story leaves to the
      project at the other, and nothing comes back — `qa_setup →
      component_linked` in, `qa_complete → qa_journey_plan` out, and
      `qa_journey_plan` is downstream of `qa_setup`;
    * a story enters the component graph from `bdd_specs_exist` and the
      component graph re-enters the story at `ready_for_qa`, downstream;
    * so no path between two component nodes passes through a story or the
      project, and no path from a component node reaches a story's kickoff.

  With those, the reduction decomposes. The component side — template and
  dependency edges — reduces on its own, once. Each story's edges reduce
  against reachability over the component side: a kickoff to a node that
  another kickoff target reaches is redundant, an exit from a node whose
  successor reaches another exit is redundant, and the story's own chain from
  kickoff to exit is redundant exactly when the components connect the two.
  The project's chain reduces against the stories the same way.

  `over/4` is the whole set, and it is the set `compute_edges/3` draws.
  `edges_derived_per_entity_match_the_pass_test` holds the two together on a
  fixture and `Shadow.diff/1` does on a live project; the three facts above
  are what that rests on, and a template edge that broke one of them would
  show up there first.

  Requirement names appear here only as data read off the edges the
  generators produce: a kickoff leaves from wherever the generator says it
  does, and an exit lands wherever it says.
  """

  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Requirements.Topology
  alias CodeMySpec.Users.Scope

  @type edge :: Topology.edge()

  @typedoc """
  Whether a node exists at the vantage being drawn. An endpoint with no row is
  not an edge, and — the same rule `compute_edges/3` applies before it reduces
  — a node with no row cannot carry a path.
  """
  @type present? :: (Topology.node_key() -> boolean())

  @typep side :: %{edges: [edge()], reach: Topology.reach()}

  @typedoc """
  Everything about the edges that does not depend on the vantage, generated
  once: the component side as generated with reachability over it, every
  ready story's edges by kind, and the project's chain. `over/3` admits and
  reduces it for one vantage.

  Generating is most of a redraw — measured on dev, 2026-09-21, at the
  unscoped vantage: 205ms to generate 138 stories' 26,942 kickoff edges and
  86ms for reachability over the component side, in a 452ms redraw — and
  none of it reads the vantage, so a drain settling ten vantages generated
  the same set ten times.
  """
  @type plan :: %{
          component_side: [edge()],
          reach: Topology.reach(),
          reduced: [edge()],
          stories: %{term() => sides()},
          project: [edge()]
        }

  @typep sides :: %{template: [edge()], kickoff: [edge()], exit: [edge()], project: [edge()]}

  @doc """
  The vantage-invariant half, generated once for a shape.

  `ctx` needs the shape and nothing more — `Preloader.topology_context/1` is
  enough, and so is a full load — and its stories should be every story a
  vantage might hold, since `over/3` selects among them.
  """
  @spec plan(Scope.t(), map(), map()) :: plan()
  def plan(scope, ctx, config) do
    ctx = RequirementGraph.edge_context(ctx, config)
    side = ctx |> RequirementGraph.component_side_edges(config) |> Enum.uniq()
    reach = Topology.reach(side)

    %{
      component_side: side,
      reach: reach,
      reduced: Topology.reduce(side, reach),
      stories: Map.new(ctx.stories, &{&1.id, RequirementGraph.story_side_edges(&1, ctx, config)}),
      project: RequirementGraph.project_side_edges(scope, config)
    }
  end

  @doc """
  Every edge of one vantage: the plan admitted and reduced for the stories
  it holds and the nodes `present?` admits.

  A story the plan does not know is skipped; it arrived between the plan's
  read and this vantage's, and its own mark redraws it with a fresh plan.
  """
  @spec over(plan(), [term()], present?()) :: [edge()]
  def over(plan, story_ids, present?) do
    side = component_side(plan, present?)

    stories =
      for id <- story_ids,
          sides = Map.get(plan.stories, id),
          do: story_side(sides, side, present?)

    project = project_side(plan.project, stories, present?)

    side.edges ++ project ++ Enum.flat_map(stories, & &1.edges)
  end

  @doc """
  Every edge over `ctx` whose endpoints `present?` admits: a plan drawn for
  its own stories, at once.
  """
  @spec over(Scope.t(), map(), map(), present?()) :: [edge()]
  def over(scope, ctx, config, present?) do
    plan = plan(scope, ctx, config)
    over(plan, Map.keys(plan.stories), present?)
  end

  @doc """
  The component side for one vantage: template and dependency edges,
  reduced, with the reachability every story is drawn against.

  Reused from the plan when the vantage holds every node the side names,
  which is every vantage in the steady state; a node with no row narrows
  the side and both are drawn again over what is left.
  """
  @spec component_side(plan(), present?()) :: side()
  def component_side(plan, present?) do
    case admit(plan.component_side, present?) do
      admitted when length(admitted) == length(plan.component_side) ->
        %{edges: plan.reduced, reach: plan.reach}

      admitted ->
        reach = Topology.reach(admitted)
        %{edges: Topology.reduce(admitted, reach), reach: reach}
    end
  end

  @doc """
  One story's edges, reduced against the component side.

  `bridges` are for `project_side/3`: one edge from each project node that
  enters this story to each the story leaves to, when the story's own chain
  connects them — a path the project's reduction cannot see from its own
  edges.
  """
  @spec story_side(sides(), side(), present?()) :: %{edges: [edge()], bridges: [edge()]}
  def story_side(sides, %{reach: reach}, present?) do
    template = admit(sides.template, present?)
    kickoff = admit(sides.kickoff, present?)
    exit = admit(sides.exit, present?)
    project = admit(sides.project, present?)

    kickoff_by_from = Enum.group_by(kickoff, & &1.from, & &1.to)
    exit_by_to = Enum.group_by(exit, & &1.to, & &1.from)

    # The paths through the components, as the story sees them: from each
    # node a kickoff leaves to each node an exit lands on, when some kickoff
    # target is or reaches some exit source.
    through_components =
      Enum.flat_map(kickoff_by_from, fn {from, targets} ->
        for {to, sources} <- exit_by_to,
            Enum.any?(targets, &touches?(reach, &1, sources)),
            do: %{from: from, to: to}
      end)

    %{
      edges:
        kept_kickoff(kickoff_by_from, reach) ++
          kept_exit(exit_by_to, reach) ++
          Topology.reduce_with(template ++ project, through_components),
      bridges: bridges(project, template ++ through_components)
    }
  end

  @doc "The project's own chain, reduced against the stories that bridge it."
  @spec project_side([edge()], [%{bridges: [edge()]}], present?()) :: [edge()]
  def project_side(template, stories, present?) do
    template = admit(template, present?)
    Topology.reduce_with(template, stories |> Enum.flat_map(& &1.bridges) |> Enum.uniq())
  end

  # A kickoff keeps the targets none of the others reach.
  defp kept_kickoff(kickoff_by_from, reach) do
    Enum.flat_map(kickoff_by_from, fn {from, targets} ->
      reach |> Topology.minimal(targets) |> Enum.map(&%{from: from, to: &1})
    end)
  end

  # Only a strictly downstream exit makes an exit redundant. Sources in the
  # same cycle must survive: treating their mutual reachability as alternate
  # exits can remove every edge into the story's completion milestone.
  defp kept_exit(exit_by_to, reach) do
    Enum.flat_map(exit_by_to, fn {to, sources} ->
      sources
      |> Enum.reject(&redundant_exit?(&1, sources, reach))
      |> Enum.map(&%{from: &1, to: to})
    end)
  end

  defp redundant_exit?(source, sources, reach) do
    Enum.any?(sources, fn other ->
      other != source and
        Topology.reaches?(reach, source, Topology.mask(reach, [other])) and
        not Topology.reaches?(reach, other, Topology.mask(reach, [source]))
    end)
  end

  # Whether `node` is one of `sources` or reaches one. Membership is asked of
  # the list, not of the reachability's bits: a node no component-side edge
  # touches has no bit, and a leaf whose first requirement is its last is
  # exactly that node — the kickoff lands on it and the exit leaves from it,
  # which is a path of length two the pass drops the story's own edge for.
  # Measured on dev the first time this was asked of the bits: 34 stories at
  # the unscoped vantage carried `bdd_specs_exist → ready_for_qa` that
  # the pass did not.
  defp touches?(reach, node, sources),
    do: node in sources or Topology.reaches?(reach, node, Topology.mask(reach, sources))

  # For each project node that enters the story and each it leaves to: the
  # pair, when the story's chain joins the two. Over the story's own edges
  # before its reduction — reachability is a fact about the graph, not about
  # which edges the reduction kept to express it.
  defp bridges(project, story_edges) do
    reach = Topology.reach(story_edges)
    entering = for %{from: {"project", _, _} = from, to: to} <- project, do: {from, to}
    leaving = for %{from: from, to: {"project", _, _} = to} <- project, do: {from, to}

    for {from, entered} <- entering,
        {left, to} <- leaving,
        entered == left or Topology.reaches?(reach, entered, Topology.mask(reach, [left])),
        do: %{from: from, to: to}
  end

  defp admit(edges, present?) do
    edges
    |> Enum.filter(fn %{from: from, to: to} -> present?.(from) and present?.(to) end)
    |> Enum.uniq()
  end
end
