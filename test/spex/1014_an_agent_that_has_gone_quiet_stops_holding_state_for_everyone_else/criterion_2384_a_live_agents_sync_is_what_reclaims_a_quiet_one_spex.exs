defmodule CodeMySpecSpex.Story1014.Criterion2384Spex do
  @moduledoc """
  Story 1014 — Criterion 2384 — A live agent's sync is what reclaims a quiet one.

  Rule: Reclaiming happens when components are synced, not on a schedule.

  Components are where the damage shows, and the sync is where someone is asking
  about them. A project nobody is touching has nobody blocked, so reclaiming
  exactly when someone needs the answer needs no scheduler at all.

  This drives the stop hook and nothing else — no sweep called directly, no task
  run by hand. If the reclaim is not wired into the sync, this fails.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecLocalWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The sync is the trigger" do
    scenario "A live agent's sync is what reclaims a quiet one" do
      given_ :synced_context_component

      given_ "the checkout that built it has gone quiet", context do
        Fixtures.all_agents_go_quiet(context.scope, 96)
        {:ok, context}
      end

      given_ "another agent is working", context do
        {:ok, Map.put(context, :live, Fixtures.live_agent_scope(context.scope))}
      end

      # It is on the page to begin with. The `then_` refutes its presence
      # afterwards, and a components page that renders nothing — or fails —
      # satisfies that whether or not anything was reclaimed.
      given_ "the quiet checkout's component is listed", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/components")

        assert render(view) =~ "ExampleContext",
               "expected the quiet checkout's component to be listed before the sweep — " <>
                 "without that, the refute below cannot fail"

        {:ok, context}
      end

      when_ "that agent stops, and nothing else runs", context do
        hook(context.live, %{"session_id" => "spex-#{System.unique_integer([:positive])}"})
        {:ok, context}
      end

      then_ "the quiet checkout's component is gone", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/components")

        refute render(view) =~ "ExampleContext",
               "nothing was reclaimed by a live agent's ordinary stop. The reclaim " <>
                 "rides on the component sync precisely so no scheduler is needed — " <>
                 "if it needs one, a project whose every agent has gone quiet can " <>
                 "never recover, which is the 3c6b6b63 case exactly."

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
