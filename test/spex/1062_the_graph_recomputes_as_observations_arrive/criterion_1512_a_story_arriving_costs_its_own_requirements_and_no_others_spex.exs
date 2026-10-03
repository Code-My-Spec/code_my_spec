defmodule CodeMySpecSpex.Story1062.Criterion3616Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3616 — A story arriving costs its own requirements and no others'.

  Rule: a change to the graph's shape recomputes the entities whose shape
  changed, not the project.

  ## Why a story is the tractable case

  `Freshness.topology/2` hashes the story id set, so every story lifecycle event
  — created, deleted, parked, released, relinked — moves the topology
  fingerprint and `compute_and_publish/3` falls through to a whole-project pass.
  On a two-story fixture that restamps every stored requirement; on this project
  it is two thousand rows and the entire edge rebuild, measured at 6489ms of a
  10203ms compute.

  None of that work is owed. `stale_entities/3` already calls a story with no
  stored rows `appeared`, `departed/2` already reaps one the context has lost,
  and `Freshness.story/2` hashes `component_id` and `ready_for_dev` — so every
  story change is caught by machinery that costs what it touches. The gate is
  doing it a second time at whole-project price.

  A component is the same case, and [[criterion 3617]] is it. That was not
  obvious: a component's arrival changes the tree its siblings hang in, and the
  edge set ends in a transitive reduction over the whole graph. Both of those
  are about *edges*, which project straight from the component and dependency
  rows without computing a verdict — `template_edges/3` — so a pass can rebuild
  every edge while recomputing only what moved.

  ## Both halves, because the second one is what a cheap fix breaks

  Dropping stories from the topology gate was tried on its own and reverted. The
  incremental branch reuses `stored_edges` wholesale, so the arriving story got
  its seven requirements and **no edges between them** — `ready_for_qa` no
  longer gated on `bdd_specs_exist`, prerequisites silently stopped gating, and
  work would be offered out of order. Nothing failed; the graph was just wrong.

  So the correctness half is asserted first and in the same scenario. A cost
  rule that can be satisfied by computing less than the truth is not a rule.

  ## What it observes

  `checked_at`, backdated first — the stamp is `truncate(:second)` into a
  precision-0 column, so two passes inside one second are indistinguishable and
  a scenario that skips the backdate reads "nothing was recomputed" whether or
  not everything was.

  Project requirements are excluded: `compute_and_publish/3` rebuilds those from
  the full context on every pass by design, and [[criterion 3615]] is the one
  that narrows them.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.StoryHelpers, only: [create_story: 2]

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  @moduletag timeout: 60_000

  spex "A story arriving is not a reason to recompute the others", criterion: 1512 do
    scenario "a story is released onto a settled graph" do
      given_ :synced_context_component

      given_ "several stories already settled", context do
        existing =
          for n <- 1..4 do
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

        {:ok, context |> Map.put(:existing, existing) |> Map.put(:before, before)}
      end

      when_ "a new story is released", context do
        arrived =
          create_story(context.scope,
            title: "Arrived after the graph settled",
            description: "and should cost only itself"
          )

        :ok = Fixtures.settle_graph(context.scope)

        graph = read_graph(context)

        {:ok,
         context
         |> Map.put(:arrived_id, arrived.id)
         |> Map.put(:after, stamps(graph))
         |> Map.put(:graph, graph)}
      end

      then_ "the arriving story's requirements are computed", context do
        mine = requirements_of(context.graph, context.arrived_id)

        assert mine != [],
               """
               The story arrived and published no requirements at all.

               Everything below is about what that arrival should *not* have
               cost. If it cost nothing because it did nothing, the scenario is
               measuring an absence rather than a saving.
               """

        {:ok, context}
      end

      then_ "and its prerequisites are there", context do
        gated = gated_requirements(context.graph, context.arrived_id)

        assert gated != [],
               """
               The arriving story's requirements carry no prerequisites.

               This is the half a cheap fix breaks. `ready_for_qa` is
               gated on `bdd_specs_exist`, `qa_complete` on the work before it;
               a story whose edges were never computed offers every one of them
               at once, in any order, and nothing anywhere says the ordering is
               missing.

               It is how the first attempt at this criterion failed: seven
               requirements, zero edges, and a green cost measurement sitting on
               top of a graph that had quietly stopped gating.

               requirements: #{length(requirements_of(context.graph, context.arrived_id))}
               gated:        #{length(gated)}
               """

        {:ok, context}
      end

      then_ "and the other stories' requirements are not recomputed", context do
        moved =
          context.before
          |> moved_between(context.after)
          |> Enum.reject(fn {type, _id, _name} -> type == "project" end)

        assert moved == [],
               """
               A story arrived and #{length(moved)} requirement(s) belonging to
               other entities were recomputed.

               `Freshness.topology_parts/2` hashes the story id set, so the
               arrival moves the topology fingerprint and the pass falls through
               to a whole-project recompute — every other story and every
               component re-derived although nothing about them changed.

               None of it is owed: a story with no stored rows is already
               `appeared` to `stale_entities/3`, which recomputes exactly it.

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

  defp requirements_of(graph, story_id) do
    (graph["nodes"] || [])
    |> Enum.filter(
      &(&1["entity_type"] == "story" and to_string(&1["entity_id"]) == to_string(story_id))
    )
  end

  # This story's requirements that are the target of an edge — the ones
  # something else has to be true before. A story with no edges at all has none.
  #
  # An edge names its endpoints by `[entity_type, entity_id, name]`, which is
  # `Topology.node_key/1`'s own shape and the same three fields each node
  # carries.
  defp gated_requirements(graph, story_id) do
    mine = graph |> requirements_of(story_id) |> MapSet.new(&key_of/1)

    (graph["edges"] || [])
    |> Enum.filter(&MapSet.member?(mine, &1["to"]))
  end

  defp key_of(node),
    do: [node["entity_type"], to_string(node["entity_id"]), node["name"]]

  defp moved_between(before, later) do
    before
    |> Enum.filter(fn {key, was} -> Map.has_key?(later, key) and Map.get(later, key) != was end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end
end
