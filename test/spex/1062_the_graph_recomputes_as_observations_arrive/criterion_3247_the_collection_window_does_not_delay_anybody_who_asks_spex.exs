defmodule CodeMySpecSpex.Story1062.Criterion3247Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3247 — The collection window does not delay anybody who asks.

  Rule: a read with observations still pending recomputes before it answers.

  The price of collapsing a burst is a window, and a window is a length of time
  during which the graph knows something the next reader does not. For a
  LiveView that is a redraw a moment late. For an agent it is the decision
  about what to work on next, made from the answer before the change — which is
  the same wrong turn story 1063 is about, arriving by a different road.

  So the window binds the writer, never the reader. A reader with observations
  pending collapses the window and recomputes before answering, rather than
  waiting it out or answering from the older pass.

  Held open at ten seconds for this scenario. At the 25ms the rest of the suite
  uses, the timer fires before a criterion can read, so "the reader collapsed
  the window" and "the reader waited out the window" are indistinguishable —
  and this criterion is only about telling those apart.

  Observed through `GET /api/projects/:project_name/requirements/graph`.

  Only the answer, not how it was reached. A first draft also asserted that the
  read left `pending: false` — that the reader had collapsed the window rather
  than stepping around it — and that is an internal property of the kind this
  story's notes record having already removed once. It is also not what the
  criterion says: `cached_graph/1` cannot answer from the older pass, because
  the observation moved the fingerprint, so the reader is current either way
  and the window never delayed it.

  What the draft did find is real and is not this criterion's business:
  `actionable_count/2` settles before reading and `cached_all/1` does not, so a
  read inside the window leaves the watcher to make the same pass again. That
  is a duplicated 4.4-second recompute on a large project, reported separately.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers

  alias CodeMySpec.Issues

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :hold_graph_window

  spex "A reader is answered from the observations in hand" do
    scenario "an observation is still inside the collection window" do
      given_ "a watched project with a graph that has been served", context do
        :ok = CodeMySpecSpex.Fixtures.watch_graph(context.scope)
        warm_graph(context)

        {:ok, Map.put(context, :before, read_graph(context))}
      end

      when_ "an observation arrives and the window is still open", context do
        {:ok, _issue} =
          Issues.create_issue(context.scope, %{
            title: "filed with the window still open",
            description: "nothing settles this; the next reader has to",
            severity: :medium
          })

        # No `settle_graph/1` here on purpose. Every other criterion on this
        # story calls it to make the recompute deterministic; this one is about
        # what happens to a reader who arrives before it.
        {:ok, context}
      end

      then_ "the reader is answered from after the observation, not before it",
            context do
        answer = read_graph(context)

        refute last_recompute(answer) == last_recompute(context.before),
               """
               A reader that arrived inside the collection window was answered
               from the computation made before the observation.

               The window exists to spare the writer repeated passes. Charging
               it to the reader means an agent decides what to work on next from
               the answer that predates the thing it would have worked on —
               which is the stale verdict of story 1063, reached by waiting
               instead of by caching.

               before: #{inspect(last_recompute(context.before))}
               after:  #{inspect(last_recompute(answer))}
               """

        {:ok, context}
      end
    end
  end
end
