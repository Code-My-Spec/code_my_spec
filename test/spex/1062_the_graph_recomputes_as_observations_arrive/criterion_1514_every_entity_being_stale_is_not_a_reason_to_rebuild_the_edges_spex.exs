defmodule CodeMySpecSpex.Story1062.Criterion3618Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3618 — Every entity being stale is not a reason to rebuild the edges.

  Rule: an observation costs work in proportion to what it changed, not to the
  size of the project.

  ## The last unconditional edge rebuild

  [[Criterion 3617]] took the edge rebuild off the topology gate: a pass now
  rebuilds the edge set when the shape moved or the node set did, and reuses it
  otherwise. One path still goes around that decision. When `verdict/5` finds
  the stale set as large as the recorded one it answers `{:all, why}`, and that
  falls through to `compute_and_publish/3` — which computes every node *and*
  every edge, whatever the shape did.

  Every entity being stale says nothing about the shape. A file going away in
  each of four components moves all four `implementation_file` verdicts and
  leaves the component set, the parents and the dependencies exactly as they
  were, so the edges a rebuild would produce are the edges already stored.

  The event path settles a row only when its answer moves, so "every entity
  recomputed" is observable only as every verdict moving — which is why the
  files that go are the implementation files, the one thing a component in
  this fixture is asked about, and the fixture ships one per component.

  ## Why that is worth a criterion rather than a note

  It is not a rounding error. Measured on this project the day this was
  written:

      2106 nodes, 6640 edges — nodes 2220ms, edges 1341ms
      1532 nodes, 2941 edges — nodes  187ms, edges  378ms
      1553 nodes, 2961 edges — nodes  266ms, edges  391ms

  On the narrow vantages the edge rebuild costs *more than every verdict in the
  project*. And `everything_stale` is not a rare path: it is what a shared input
  moving produces, and what every checkout produced once when the fingerprint
  formula last changed.

  ## What it observes, and why not queries

  `edges_rebuilt`, off the drain's own cost report.

  Queries and rows written are the instruments the other cost criteria use and
  neither can see this. An edge rebuild that produces the set already stored
  deletes nothing — `delete_edges_outside/2` keeps every pair it was handed —
  and inserts nothing, since `insert_every/3` is `on_conflict: :nothing`. It
  resolves its ids from the map the node write already returned, so no extra
  query is issued either. The work is a transitive reduction over the whole
  graph, in memory, and it is invisible at the database.

  So the pass says it out loud. `DrainCost.measure/2` counts the announcement
  the same way it counts queries, filtered to the drain's own process.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens
  import CodeMySpecSpex.GraphReadHelpers

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.GraphContentFixtures, as: Content

  setup :register_log_in_setup_account
  setup :setup_active_project

  @moduletag timeout: 60_000

  # The fixture's own four. Their specs — types, parents, `Stories` declaring
  # `Users` — are not touched, or the shape genuinely moved and the scenario is
  # measuring a rebuild that was owed.
  @modules ~w(Users Users.Account Stories Stories.Story)

  spex "A pass rebuilds the edges when the shape moved, not when everything is stale",
    criterion: 1514 do
    scenario "every component loses a file and the shape does not move" do
      given_ :cross_context_dependency

      given_ "a settled graph", context do
        :ok = Fixtures.settle_graph(context.scope)
        _warm = read_settled_graph(context)
        :ok = Fixtures.settle_graph(context.scope)

        # Old enough that the rewrite below is visible. `checked_at` is
        # `truncate(:second)` into a precision-0 column, so a pass that
        # recomputes everything inside one second is indistinguishable from one
        # that recomputed nothing — and this scenario reads "nothing moved" as
        # its own setup having failed.
        :ok = Fixtures.backdate_requirement_freshness(context.scope)

        graph = read_graph(context)

        assert graph["nodes"] != [], "nothing is stored, so no pass can reuse anything"

        assert graph["edges"] != [],
               """
               The settled graph carries no edges, so "the edges were reused"
               is a claim about nothing.

               `:cross_context_dependency` is four components in two contexts
               with a declared dependency between them; if that produced no
               edges the fixture is not the topology this criterion needs.
               """

        {:ok, Map.put(context, :before, graph)}
      end

      when_ "every one of their implementation files goes away", context do
        # Four verdicts move and the shape does not: `Freshness.topology/2`
        # hashes ids, types, parents and dependencies, and a file going away
        # touches none of them.
        for module_name <- @modules do
          :ok = Fixtures.delete_env_file(context.environment, Content.impl_path(module_name))
        end

        :ok = Fixtures.scan_working_copy(context.scope)
        :ok = Fixtures.settle_graph(context.scope)

        {:ok, Map.put(context, :after, read_graph(context))}
      end

      then_ "every component is recomputed", context do
        moved =
          context.before
          |> stamps()
          |> Enum.filter(fn {key, was} -> Map.get(stamps(context.after), key) != was end)

        assert moved != [],
               """
               Four implementation files went away and no verdict moved.

               This criterion is about what that pass should *not* also do. If
               it did nothing at all, the saving below is an absence rather than
               a saving, and the scenario is green for the wrong reason.
               """

        {:ok, context}
      end

      then_ "and the graph still carries the same edges", context do
        assert edge_set(context.after) == edge_set(context.before),
               """
               The edge set changed although the shape did not.

               Nothing here touched a component's type, its parent or its
               dependencies, so every edge the graph had it should still have.
               A difference means the pass either rebuilt them wrongly or
               dropped the ones it reused — and either way the cost claim below
               would be measuring a graph that had stopped being correct.

               before: #{MapSet.size(edge_set(context.before))} edges
               after:  #{MapSet.size(edge_set(context.after))} edges
               """

        {:ok, context}
      end

      then_ "and it did not rebuild them to find that out", context do
        rebuilt = rebuilds(context.after["last_drain"])

        assert rebuilt == 0,
               """
               Every entity was stale, the shape had not moved, and the pass
               rebuilt the edge set #{inspect(rebuilt)} time(s) anyway.

               `verdict/5` answers `{:all, why}` when the stale set is as large
               as the recorded one, and that falls through to
               `compute_and_publish/3`, which rebuilds every edge whatever the
               shape did. But "every entity's inputs moved" is a statement about
               verdicts; the edges come from the component and dependency rows,
               and those are exactly what did not move.

               It is the expensive half: 6640 edges at 1341ms against 2220ms of
               node computation on this project, and more than every verdict in
               the project on a narrower checkout.
               """

        {:ok, context}
      end
    end
  end

  defp stamps(graph) do
    (graph["nodes"] || [])
    |> Map.new(&{{&1["entity_type"], to_string(&1["entity_id"]), &1["name"]}, &1["checked_at"]})
  end

  defp edge_set(graph), do: MapSet.new(graph["edges"] || [], &{&1["from"], &1["to"]})

  # How many times the last drain rebuilt the edge set — the drain of whichever
  # writer serves the graph, which is what `last_drain` reports. `nil` rather
  # than 0 when the drain reported nothing, so "no reading" cannot be read as
  # "no rebuild".
  defp rebuilds(%{"edges_rebuilt" => rebuilt}), do: rebuilt
  defp rebuilds(_other), do: nil
end
