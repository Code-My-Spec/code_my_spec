defmodule CodeMySpecSpex.Story1062.Criterion3351Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3351 — A steady stream still gets a pass.

  Rule: a burst of observations collapses into one update.

  Coalescing, not throttling. The debounce timer is scheduled by the first
  event and is *not* extended by later ones, so a project being written to
  continuously still gets a pass every window rather than never getting one.

  The distinction matters because the obvious implementation is the wrong one:
  resetting the timer on each event is what "debounce" usually means, and under
  a steady stream it produces a graph that is never recomputed at all — the
  exact silence this story exists to end, arriving through the mechanism
  meant to prevent it.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers

  alias CodeMySpec.Issues

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A project under continuous writes is still recomputed" do
    scenario "writes keep arriving with no pause between them" do
      given_ "a project whose graph has been served", context do
        {:ok, warm_graph(context) |> Map.put(:before, read_graph(context))}
      end

      when_ "writes arrive continuously, none of them pausing", context do
        # No settle. A settle would prove the pass can be forced and say
        # nothing about whether a stream that never pauses gets one on its own.
        for n <- 1..6 do
          {:ok, _issue} =
            Issues.create_issue(context.scope, %{
              title: "stream #{n}",
              description: "arriving without a pause",
              severity: :low
            })
        end

        {:ok, context}
      end

      then_ "the graph has been recomputed rather than waiting for a lull", context do
        after_stream = read_graph(context)

        refute last_recompute(after_stream) == last_recompute(context.before),
               """
               A continuous stream of writes left the graph answering from the
               computation it made before any of them.

               Coalescing is not throttling: the timer is scheduled by the first
               event and must not be extended by later ones. Resetting it per
               event is what debounce usually means, and under a steady stream
               it produces a graph that is never recomputed — the silence this
               story exists to end, arriving through the mechanism meant to
               prevent it.

               before: #{inspect(last_recompute(context.before))}
               after:  #{inspect(last_recompute(after_stream))}
               """

        {:ok, context}
      end
    end
  end
end
