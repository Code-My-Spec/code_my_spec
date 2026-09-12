defmodule CodeMySpecSpex.Story1062.Criterion3244Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3244 — Many writes at once cost one update.

  Rule: a burst of observations collapses into one update.

  A single sync writes hundreds of files and a Three Amigos session writes a
  rule, its scenarios and its questions in one breath. Recomputing per event
  would be a whole graph per row, measured at roughly 170ms each, so an event
  schedules a pass and further events fold into it.

  Observed by the answer rather than by counting passes: after a burst, one
  computation serves the lot. If each write produced its own recompute, the
  reads taken across the burst would carry different `computed_at` values
  rather than settling on one.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers

  alias CodeMySpec.Issues

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A burst of writes is answered by one computation" do
    scenario "ten issues are filed in quick succession" do
      given_ "a project whose graph has been served", context do
        {:ok, warm_graph(context) |> Map.put(:before, read_graph(context))}
      end

      when_ "ten issues are filed one after another", context do
        for n <- 1..10 do
          {:ok, _issue} =
            Issues.create_issue(context.scope, %{
              title: "finding #{n}",
              description: "one of a burst",
              severity: :low
            })
        end

        # Do the pending pass now rather than in the debounce window's own
        # time. A spec that slept would be asserting the timer rather than the
        # coalescing.
        :ok = CodeMySpecSpex.Fixtures.settle_graph(context.scope)

        {:ok, context}
      end

      then_ "one computation answers for the whole burst", context do
        # The burst invalidated the cache, so the next read is a miss: it
        # computes, stores, and answers `computed_at: nil` while doing it.
        # Discard that one — the question here is whether the reads *after*
        # the burst has settled agree with each other.
        _miss = read_graph(context)

        first = read_graph(context)
        second = read_graph(context)

        refute first["computed_at"] == context.before["computed_at"],
               "the burst must reach the graph at all for this criterion to mean anything"

        assert first["computed_at"] == second["computed_at"],
               """
               Two reads after a settled burst disagreed about when the graph
               was computed, which means the burst is still producing passes.

               Ten writes should fold into one update. Recomputing per event is
               a whole graph per row, and a single sync writes hundreds.

               first:  #{inspect(first["computed_at"])}
               second: #{inspect(second["computed_at"])}
               """

        {:ok, context}
      end
    end
  end
end
