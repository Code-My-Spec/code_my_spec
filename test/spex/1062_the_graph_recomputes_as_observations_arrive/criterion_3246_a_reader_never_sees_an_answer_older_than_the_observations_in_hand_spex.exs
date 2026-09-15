defmodule CodeMySpecSpex.Story1062.Criterion3246Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3246 — A reader never sees an answer older than the observations in
  hand.

  Rule: a read with observations still pending recomputes before it answers.

  The debounce buys batching at the cost of a window in which the graph knows
  something the next answer does not. This closes that window from the reader's
  side: whatever is pending is folded in before the answer goes out.

  It matters most for the reader who is about to act on it. An agent's read is
  the one that decides what it works on next, and answering a beat before the
  pending recompute means deciding from the older picture — then being handed
  the same work again once the timer fires.

  Paired with 3353, which says a read with *nothing* pending must not recompute.
  Together they are the difference between "settle when there is something to
  settle" and "recompute on every read".
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers

  alias CodeMySpec.Issues

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A pending observation is folded in before the answer goes out" do
    scenario "a write lands and is read immediately, inside the collection window" do
      given_ "a project whose graph has been served", context do
        {:ok, warm_graph(context) |> Map.put(:before, read_graph(context))}
      end

      when_ "an issue is filed and the graph is read straight away", context do
        {:ok, _issue} =
          Issues.create_issue(context.scope, %{
            title: "filed and read in the same breath",
            description: "inside the collection window",
            severity: :medium
          })

        # Deliberately no settle: the point is that the READ does it. Settling
        # here would prove the debounce works and say nothing about whether a
        # reader is protected from it.
        {:ok, Map.put(context, :immediate, read_graph(context))}
      end

      then_ "the answer accounts for the write rather than predating it", context do
        refute last_recompute(context.immediate) == last_recompute(context.before),
               """
               A read taken immediately after a write answered from the
               computation made before it.

               The debounce window is the gap in which the graph knows
               something its next answer does not. A reader has to be protected
               from that gap, or an agent decides what to work on from the older
               picture and is handed the same work again when the timer fires.

               before:    #{inspect(last_recompute(context.before))}
               immediate: #{inspect(last_recompute(context.immediate))}
               """

        {:ok, context}
      end
    end
  end
end
