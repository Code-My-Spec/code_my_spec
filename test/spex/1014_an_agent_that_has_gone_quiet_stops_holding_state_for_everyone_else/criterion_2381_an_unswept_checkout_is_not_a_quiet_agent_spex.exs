defmodule CodeMySpecSpex.Story1014.Criterion2381Spex do
  @moduledoc """
  Story 1014 — Criterion 2381 — An unswept checkout is not a quiet agent.

  Rule: Liveness is read from the agent, never from the age of the rows it
  produced.

  Rows update on scans, and scans happen on hooks rather than on activity. This
  working copy went unswept from 10:13 to 13:44 while being actively worked,
  because the harness was busy holding other copies. A one-hour file-age rule
  would have reclaimed a live agent mid-session.

  Agent liveness is one clock and one decision. Row age is thousands of
  independent ones, none of which means what it looks like.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecLocalWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Liveness is the agent's, not its rows'" do
    scenario "An unswept checkout is not a quiet agent" do
      given_ :synced_context_component

      given_ "its rows are old but the agent is not", context do
        Fixtures.age_files_of(context.scope, 96)
        Fixtures.all_agents_go_quiet(context.scope, 0)

        {:ok, context}
      end

      given_ "another agent is working too", context do
        {:ok, Map.put(context, :live, Fixtures.live_agent_scope(context.scope))}
      end

      when_ "the other agent stops, which syncs components", context do
        post_hook(context.live, "/api/hooks/stop", %{
          "session_id" => "spex-#{System.unique_integer([:positive])}"
        })

        {:ok, context}
      end

      then_ "nothing of the unswept agent's was reclaimed", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/components")

        assert render(view) =~ "ExampleContext",
               "an agent was reclaimed because its rows were old, not because it " <>
                 "was gone. Scans happen on hooks rather than on activity, so a busy " <>
                 "harness leaves a live agent's rows untouched for hours — this " <>
                 "working copy went 3.5 hours unswept while being actively worked."

        {:ok, context}
      end
    end
  end
end
