defmodule CodeMySpecSpex.Story1062.Criterion3621Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3621 — Seeding a checkout computes the project once and writes it
  once.

  Rule: an observation costs work in proportion to what it changed, not to the
  size of the project.

  ## The most expensive thing the event path did was start

  Measured on dev, 2026-09-21, twice — once after each promote:

      [DrainCost] event drain in 17945ms — 26395 queries, 14945 rows written
                  (handled: 0, observations: 0, recomputed: 0, vantages: 9)

  `observations: 0`. Nothing had happened; the process had merely restarted,
  and the seed that gives an accumulated projection its starting state cost
  eighteen seconds and twenty-six thousand queries. Every restart, every
  promote.

  Two things made it that, and both were per-entity where they should have been
  per-project. `run(:everything)` computed each entity on its own —
  `compute_entity/4` and a `GraphStore.write/3` transaction, ~1,300 times per
  vantage — and then called `reproject_topology/3`, which computed every node a
  second time to get the edges. And `reap/4` inside each of those writes issued
  one `DELETE` per covered entity.

  ## What it observes

  `projection_writes`, off the drain's own cost report — how many write
  transactions the event path opened. One per seed is the claim.

  Queries could not name this. A transaction is a handful of queries however
  many rows it carries, so the number that says "per entity" is the number of
  transactions, and a fixture of four components cannot make the query count
  differ by enough to separate the two shapes. Counting the thing itself does:
  four entities plus the project is five writes the old way and one the new.

  ## What it does not observe, and where that is asserted

  That every requirement and edge was written. The rows the event path writes
  are its own tables and no served surface reads them — that is by design, and
  `GraphStore.diff/1` is the unit-level oracle that compares them against the
  pass, row for row and edge for edge (`the_flag_is_a_switch_not_a_trap_test`
  and `graph_store_test` assert on it). A criterion here about the rows' contents
  would be a rule about scaffolding, and John was explicit that there are to be
  none.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens
  import Phoenix.LiveViewTest

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  @moduletag timeout: 60_000

  spex "A seed is one computation and one write", criterion: 1517 do
    scenario "the event path meets a project it has never projected" do
      given_ :cross_context_dependency

      given_ "a pass has run, so there is something to seed from", context do
        Fixtures.watch_graph(context.scope)
        :ok = Fixtures.settle_graph(context.scope)

        {:ok, context}
      end

      when_ "the event path seeds the checkout", context do
        # A projector arriving trusts the rows it finds, so the ones the
        # project's construction left are taken away first and the projector
        # is restarted: it meets the checkout with nothing of its own and
        # seeds. The drain it reports is the seed and nothing else, because
        # nothing else has been announced.
        Fixtures.stop_graph_watchers()
        :ok = Fixtures.forget_projection(context.scope)
        Fixtures.watch_graph(context.scope)
        :ok = Fixtures.settle_graph(context.scope)

        {:ok, Map.put(context, :seed, event_drain(context))}
      end

      then_ "the seed happened and was measured", context do
        assert context.seed,
               """
               The page publishes no `event` drain, so the seed either did not
               run or did not report what it cost.

               `GraphWatcher.settle/2` drains the projector, and a projector that
               has not seeded seeds on its first drain. One of those did not happen.
               """

        {:ok, context}
      end

      then_ "and it wrote the projection once per checkout, not once per entity", context do
        writes = context.seed.projection_writes
        vantages = context.seed.vantages

        assert is_integer(vantages) and vantages >= 1,
               "the drain reports no checkout count, so \"once per checkout\" has nothing to be measured against"

        # One write per vantage seeded. A seed runs for every live vantage —
        # `nil` and each checkout — and each is its own projection, so the
        # honest count is the vantage count, not one. Checked on a known
        # positive before trusting it: the per-entity seed reads 6 here, this
        # reads 2 for 2 vantages.
        assert writes == vantages,
               """
               Seeding #{vantages} checkout(s) opened #{inspect(writes)} write
               transaction(s) for a project of four components.

               `run(:everything)` used to compute and write each entity on its
               own and then recompute every node again for the edges. On a
               fixture that is five transactions; on dev it was ~1,300 per
               vantage across nine vantages — 17.9 seconds and 26,395 queries
               on every restart, with `observations: 0`.

               `compute_topology/3` is one computation of every node and every
               edge. One write follows it.
               """

        {:ok, context}
      end
    end
  end

  # The last event drain, off the dev page — the same per-kind row criterion
  # 3516 reads, with the one field this criterion is about.
  defp event_drain(context) do
    {:ok, view, _html} = live(context.conn, "/dev/graph")
    html = render_change(view, "select", %{"project" => context.project.id})

    ~r/data-test="drain" data-kind="event"(.*?)<\/div>/s
    |> Regex.run(html)
    |> then(fn
      [_match, body] ->
        %{
          projection_writes: number(body, "drain-projection-writes"),
          vantages: number(body, "drain-vantages")
        }

      nil ->
        nil
    end)
  end

  # `\s*` because the formatter wraps a span whose text runs long, and the
  # digits then open on the next line.
  defp number(body, field) do
    ~r/data-test="#{field}">\s*(\d+)/
    |> Regex.run(body)
    |> then(fn
      [_, digits] -> String.to_integer(digits)
      nil -> nil
    end)
  end
end
