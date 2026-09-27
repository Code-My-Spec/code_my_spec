defmodule CodeMySpecSpex.Story1062.Criterion3617Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3617 — A component arriving costs its own requirements and no others'.

  Rule: a change to the graph's shape recomputes the entities whose shape
  changed, not the project.

  ## The half that was called intractable

  [[Criterion 3616]] is the same rule for a story, and its first draft argued a
  component could not follow: its arrival changes the tree its siblings hang
  in, `expand_component_families/2` exists because that spreads, and the edge
  set ends in a transitive reduction over the whole graph.

  Two of those three are about **edges**, and edges are not the expensive half.
  The components and their dependency rows *are* the shape — `build_id_map/3`
  reads a component's id and its children's ids, `component_tree_edges/2` reads
  `parent_component_id`, `cross_context_dependency_edges/2` reads the
  dependency rows — so the whole edge set projects from those rows directly,
  without computing one verdict. `template_edges/3` is that projection, and it
  is what lets a pass rebuild every edge while recomputing only the components
  whose own inputs moved.

  The third — the family closure — is a *node* question, and
  `expand_component_families/2` already answers it at the right price.

  ## What it observes

  `checked_at`, backdated first, because the stamp is `truncate(:second)` into
  a precision-0 column and two passes inside one second are indistinguishable.

  And the dependency edge, because this is the criterion where a cheap fix is
  most tempting and most wrong. A component whose spec declares a dependency
  and whose graph carries no edge for it is a context that can be built before
  the thing it is built on — silently, with every requirement present and
  correct.

  Project requirements are excluded: `compute_and_publish/3` rebuilds those
  from the full context by design, and [[criterion 3615]] is the one that
  narrows them.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.StoryHelpers, only: [create_story: 2]
  import Phoenix.LiveViewTest

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  @moduletag timeout: 60_000

  @arriving "Billing"
  @arriving_spec ".code_my_spec/spec/billing.spec.md"
  @arriving_impl "lib/billing.ex"

  spex "A component arriving is not a reason to recompute the others" do
    scenario "a context is synced onto a settled graph" do
      given_ :synced_context_component

      given_ "a settled graph with work already in it", context do
        for n <- 1..3 do
          create_story(context.scope,
            title: "Already here #{n}",
            description: "settled before the arrival"
          )
        end

        :ok = Fixtures.settle_graph(context.scope)
        _warm = read_settled_graph(context)
        :ok = Fixtures.settle_graph(context.scope)

        # Old enough that a rewrite is visible at second resolution.
        :ok = Fixtures.backdate_requirement_freshness(context.scope)

        before = stamps(read_graph(context))

        assert before != %{},
               "nothing is stored, so no arrival can leave anything alone"

        {:ok, Map.put(context, :before, before)}
      end

      when_ "a new context's spec is synced, declaring a dependency", context do
        :ok = Environments.write_file(context.environment, @arriving_spec, spec_file())
        :ok = Environments.write_file(context.environment, @arriving_impl, impl_file())

        {:ok, files, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        files |> element("button[phx-click='sync']") |> render_click()

        :ok = Fixtures.settle_graph(context.scope)

        arrived = Fixtures.get_component_by_module_name(context.scope, @arriving)

        assert %_{} = arrived,
               "the sync did not produce a component, so nothing arrived to measure"

        graph = read_graph(context)

        {:ok,
         context
         |> Map.put(:arrived, arrived)
         |> Map.put(:after, stamps(graph))
         |> Map.put(:graph, graph)}
      end

      then_ "the arriving component's requirements are computed", context do
        mine = requirements_of(context.graph, context.arrived.id)

        assert mine != [],
               """
               The component arrived and published no requirements at all.

               Everything below is about what that arrival should *not* have
               cost. If it cost nothing because it did nothing, the scenario is
               measuring an absence rather than a saving.
               """

        {:ok, context}
      end

      then_ "and its prerequisites are there", context do
        gated = gated_requirements(context.graph, context.arrived.id)

        assert gated != [],
               """
               The arriving component's requirements carry no prerequisites.

               A component's template is a chain — the spec before the review,
               the review before the implementation, the implementation before
               its tests — and a component whose edges were never computed
               offers every link at once, in any order. Nothing says the
               ordering is missing; the work simply comes out wrong.

               requirements: #{length(requirements_of(context.graph, context.arrived.id))}
               gated:        #{length(gated)}
               """

        {:ok, context}
      end

      then_ "and the dependency it declared is an edge in the graph", context do
        assert dependency_edge(context.graph, context.component.id, context.arrived.id) != nil,
               """
               #{@arriving}'s spec declares a dependency on #{context.component.module_name}
               and the graph carries no edge between them.

               This is the half a cheap fix breaks, and it breaks quietly: every
               requirement is present, every verdict is right, and the context
               can be built before the thing it is built on.

               The dependency rows are the shape — `cross_context_dependency_edges/2`
               reads nothing else — so an edge missing here is a pass that
               reused a stored edge set from before the component existed.
               """

        {:ok, context}
      end

      then_ "and the other entities' requirements are not recomputed", context do
        moved =
          context.before
          |> moved_between(context.after)
          |> Enum.reject(fn {type, _id, _name} -> type == "project" end)

        assert moved == [],
               """
               A component arrived and #{length(moved)} requirement(s) belonging
               to other entities were recomputed.

               `Freshness.topology_parts/2` hashes every component's id, type,
               parent and dependencies, so the arrival moves the shape — which
               is true, and is a statement about edges. The nodes are not owed:
               a component with no stored rows is already `appeared` to
               `stale_entities/3`, and `expand_component_families/2` adds the
               relatives whose own node sets its arrival changed.

               moved: #{moved |> Enum.take(6) |> Enum.map_join(", ", fn {t, _i, n} -> "#{t}/#{n}" end)}
               """

        {:ok, context}
      end
    end
  end

  defp stamps(graph) do
    (graph["nodes"] || [])
    |> Map.new(&{{&1["entity_type"], to_string(&1["entity_id"]), &1["name"]}, &1["checked_at"]})
  end

  defp requirements_of(graph, component_id) do
    (graph["nodes"] || [])
    |> Enum.filter(
      &(&1["entity_type"] == "component" and
          to_string(&1["entity_id"]) == to_string(component_id))
    )
  end

  # Requirements of this component that something else has to be true before.
  # An edge names its endpoints by `[entity_type, entity_id, name]`, which is
  # `Topology.node_key/1`'s own shape and the same three fields each node
  # carries.
  defp gated_requirements(graph, component_id) do
    mine = graph |> requirements_of(component_id) |> MapSet.new(&key_of/1)

    (graph["edges"] || []) |> Enum.filter(&MapSet.member?(mine, &1["to"]))
  end

  # An edge out of the dependency and into the dependent. `component_boundary/4`
  # draws it from the dependency's last requirement to the dependent's first, so
  # the direction is fixed and worth asserting rather than accepting either way.
  defp dependency_edge(graph, depends_on_id, dependent_id) do
    from = graph |> requirements_of(depends_on_id) |> MapSet.new(&key_of/1)
    to = graph |> requirements_of(dependent_id) |> MapSet.new(&key_of/1)

    Enum.find(
      graph["edges"] || [],
      &(MapSet.member?(from, &1["from"]) and MapSet.member?(to, &1["to"]))
    )
  end

  defp key_of(node),
    do: [node["entity_type"], to_string(node["entity_id"]), node["name"]]

  defp moved_between(before, later) do
    before
    |> Enum.filter(fn {key, was} -> Map.has_key?(later, key) and Map.get(later, key) != was end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp spec_file do
    """
    # #{@arriving}

    ## Type

    context

    Charges for what the example context did.

    ## Functions

    ### charge/1

    Charges an account.

    ```elixir
    @spec charge(term()) :: :ok
    ```

    ## Dependencies

    - ExampleContext

    ## Components

    ### #{@arriving}.Charge

    Placeholder child module.
    """
  end

  defp impl_file do
    """
    defmodule #{@arriving} do
      @moduledoc false

      def charge(_account), do: :ok
    end
    """
  end
end
