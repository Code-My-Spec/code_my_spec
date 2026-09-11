defmodule CodeMySpecSpex.Story1062.Criterion3245Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3245 — The change is announced for whoever is listening.

  Rule: the graph announces that it changed.

  The recompute is the work; the announcement is how anything other than the
  next reader learns it happened. Without it the only way to discover a moved
  graph is to ask, which is the read-triggered world this story replaced.

  Deliberately indifferent to who is listening, and to whether anyone is. The
  graph's job ends at saying so — deciding whether a change matters belongs to
  the listener, which is what keeps the announcement free of routing and what
  lets a listener be added later without the graph knowing.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers

  alias CodeMySpec.Issues

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A recompute announces itself" do
    scenario "a listener is subscribed when an observation arrives" do
      given_ "a watched project with a listener subscribed to it", context do
        :ok = CodeMySpecSpex.Fixtures.watch_graph(context.scope)
        {:ok, warm_graph(context)}
      end

      when_ "an observation arrives", context do
        {:ok, _issue} =
          Issues.create_issue(context.scope, %{
            title: "an observation worth announcing",
            description: "filed with a listener attached",
            severity: :medium
          })

        :ok = CodeMySpecSpex.Fixtures.settle_graph(context.scope)

        {:ok, context}
      end

      then_ "the listener is told the graph changed", context do
        project_id = context.scope.active_project_id

        receive do
          {:graph_updated, ^project_id} ->
            {:ok, context}
        after
          2_000 ->
            flunk("""
            The graph recomputed and told nobody.

            The recompute is the work; the announcement is how anything other
            than the next reader learns it happened. Without it, discovering a
            moved graph means asking — which is the read-triggered behaviour
            this story replaced.

            Check that a watcher is running: `settle/1` answers :ok when
            nothing is watching, so a missing watcher looks exactly like a
            missing announcement.
            """)
        end
      end
    end
  end
end
