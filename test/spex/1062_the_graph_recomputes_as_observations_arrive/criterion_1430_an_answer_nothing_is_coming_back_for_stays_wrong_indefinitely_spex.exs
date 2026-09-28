defmodule CodeMySpecSpex.Story1062.Criterion3522Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3522 — An answer nothing is coming back for stays wrong
  indefinitely.

  Rule: nothing sweeps. A row is corrected by an observation that names it, or
  it is not corrected.

  ## A criterion that asserts an absence, on purpose

  Every other rule on this story bounds what the graph *does*. This one pins
  what it deliberately does not: there is no background pass, no repair loop, no
  read that quietly recomputes what it is serving. A row is as right as the last
  observation that named it and no righter.

  That is worth writing down because the alternative is so tempting. A periodic
  sweep would paper over every bug the rest of this story is about — a handler
  that settles the wrong requirement, an observation narrowed to the wrong
  checkout, a mark consumed before its work — and it would paper over them
  *intermittently*, which is worse than not at all. The failures would become
  flakes and the cost rules would become unmeasurable, because the sweep's work
  would be attributed to whatever observation happened to be in flight.

  So the safety net is refused, and its absence is the thing that makes
  [[criterion 3523]] load-bearing: since nothing is coming back, the observation
  that moved a requirement has to be the one that settles it.

  ## What it observes

  Rows stamped as computed some time ago, read twice with nothing happening in
  between. If a read recomputed, or anything swept, the stamps would move. They
  do not — and that same mechanism is what leaves a genuinely wrong answer wrong
  for as long as the project is quiet.

  The staleness is manufactured rather than a real defect, and it has to be:
  inducing a genuinely wrong verdict would mean breaking a handler, and the
  criterion is about what happens *afterwards*, which is identical either way.
  What is being asserted is that nothing comes back — not the reason the answer
  needed correcting.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  @moduletag timeout: 60_000

  spex "Nothing comes back for an answer nobody names", criterion: 1430 do
    scenario "rows are left stale and the project goes quiet" do
      given_ :synced_context_component

      given_ "a settled graph whose rows were computed some time ago", context do
        _warm = read_settled_graph(context)
        :ok = Fixtures.settle_graph(context.scope)
        :ok = Fixtures.backdate_requirement_freshness(context.scope)

        stamps = stamps(read_graph(context))

        assert stamps != %{},
               "nothing is stored, so there is no answer for anything to come back for"

        {:ok, Map.put(context, :stale, stamps)}
      end

      when_ "nothing else happens to name those entities", context do
        # No observation, no sync, no write. Just reads — which is what a quiet
        # project is: agents asking what to do and being answered from rows.
        first = stamps(read_graph(context))
        second = stamps(read_graph(context))

        {:ok, context |> Map.put(:first, first) |> Map.put(:second, second)}
      end

      then_ "the answers are still the ones that were there", context do
        assert context.first == context.stale,
               """
               #{changed_count(context.stale, context.first)} requirement(s) were
               recomputed by a read.

               Reads serve rows. A read that recomputes is the behaviour this
               story removed from the read path, and it would make every cost
               rule here unmeasurable — the work would be attributed to whoever
               happened to look rather than to the observation that caused it.
               """

        {:ok, context}
      end

      then_ "and they stay that way for as long as the project is quiet", context do
        assert context.second == context.stale,
               """
               #{changed_count(context.stale, context.second)} requirement(s)
               moved between two reads with nothing happening in between.

               Something is sweeping. A background repair pass papers over every
               defect the rest of this story is about — a handler settling the
               wrong requirement, an observation narrowed to the wrong checkout,
               a mark consumed before its work — and papers over them
               intermittently, which turns each of them into a flake and makes
               the cost rules unattributable.

               The absence is the design. It is what obliges the observation
               that moved a requirement to be the one that settles it.
               """

        {:ok, context}
      end
    end
  end

  defp stamps(graph) do
    (graph["nodes"] || [])
    |> Map.new(&{{&1["entity_type"], to_string(&1["entity_id"]), &1["name"]}, &1["checked_at"]})
  end

  defp changed_count(before, later) do
    Enum.count(before, fn {key, was} -> Map.get(later, key, was) != was end)
  end
end
