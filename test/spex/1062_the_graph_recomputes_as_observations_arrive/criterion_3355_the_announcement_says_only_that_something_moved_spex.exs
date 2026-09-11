defmodule CodeMySpecSpex.Story1062.Criterion3355Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3355 — The announcement says only that something moved.

  Rule: the graph announces that it changed.

  Deliberately no payload. What changed is not interesting; whether the answer
  changed is — and the graph itself is the authority on that, so a listener
  asks it rather than being told.

  This is what resolves the apparent tension with story 1050 (an agent is told
  only about work for its own role) without putting routing in the event. The
  listener's own query is already role-scoped and working-copy-scoped by
  construction, and it cannot drift from the graph because it *is* the graph. A
  payload describing the change would be a second account of it, and the first
  thing to go stale.

  Observed by subscribing the way a listener does and reading what arrives.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers

  alias CodeMySpec.Issues

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The change announcement carries no account of the change" do
    scenario "a listener is subscribed when the graph moves" do
      given_ "a watched project with a listener subscribed to it", context do
        :ok = CodeMySpecSpex.Fixtures.watch_graph(context.scope)

        {:ok, warm_graph(context)}
      end

      when_ "an issue is filed and the graph recomputes", context do
        {:ok, _issue} =
          Issues.create_issue(context.scope, %{
            title: "something a listener might care about",
            description: "or might not — the announcement does not say",
            severity: :medium
          })

        :ok = CodeMySpecSpex.Fixtures.settle_graph(context.scope)

        {:ok, context}
      end

      then_ "the announcement names the project and nothing else", context do
        project_id = context.scope.active_project_id

        announcement =
          receive do
            {:graph_updated, ^project_id} = msg -> msg
          after
            2_000 ->
              flunk("""
              The graph never announced a change.

              Check that `ensure_watching/1` ran — without a watcher nothing
              recomputes and nothing is published, and `settle/1` answers :ok
              when nothing is watching, so a missing watcher looks exactly like
              a missing announcement.
              """)
          end

        assert announcement == {:graph_updated, project_id},
               """
               The announcement carried more than the project it concerns.

               What changed is not interesting; whether the answer changed is,
               and the graph is the authority on that. A payload describing the
               change is a second account of it and the first thing to drift —
               and the listener's own query is already scoped correctly by
               construction.

               got: #{inspect(announcement)}
               """

        {:ok, context}
      end
    end
  end
end
