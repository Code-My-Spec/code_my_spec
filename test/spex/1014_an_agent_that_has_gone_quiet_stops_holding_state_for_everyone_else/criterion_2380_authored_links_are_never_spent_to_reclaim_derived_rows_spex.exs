defmodule CodeMySpecSpex.Story1014.Criterion2380Spex do
  @moduledoc """
  Story 1014 — Criterion 2380 — Authored links are never spent to reclaim derived
  rows.

  Rule: A component is reclaimed only when it has no files and no story
  references it.

  `stories.component_id` points at components. Losing an authored link to reclaim
  a derived row is a bad trade: authored data is project-scoped and shared, which
  is the line story 727 draws. Prune only when nothing references it; otherwise
  leave it and let the orphan rule filter it out.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecLocalWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A story's link outlives the agent that built the component" do
    scenario "Authored links are never spent to reclaim derived rows" do
      given_ :synced_context_component
      given_ :story_linked_to_component

      given_ "the checkout that built it has been quiet for days", context do
        Fixtures.all_agents_go_quiet(context.scope, 96)
        {:ok, context}
      end

      given_ "another agent is working", context do
        {:ok, Map.put(context, :live, Fixtures.live_agent_scope(context.scope))}
      end

      when_ "the live agent stops, which syncs components", context do
        hook(context.live, %{"session_id" => "spex-#{System.unique_integer([:positive])}"})
        {:ok, context}
      end

      then_ "the component a story points at survives", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/components")

        assert render(view) =~ "ExampleContext",
               "a component a story is linked to was reclaimed because its files " <>
                 "belonged to a quiet checkout. The link is authored — someone " <>
                 "decided it — and authored data is project-scoped and shared. " <>
                 "Spending it to reclaim a derived row trades something nobody can " <>
                 "regenerate for something that regenerates on the next sync."

        {:ok, context}
      end
    end
  end

  defp hook(scope, params) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("x-harness-id", scope.active_harness_id)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Phoenix.ConnTest.dispatch(@endpoint, :post, "/api/hooks/stop", params)
    |> Phoenix.ConnTest.json_response(200)
  end
end
