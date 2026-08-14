defmodule CodeMySpecSpex.Story1014.Criterion2377Spex do
  @moduledoc """
  Story 1014 — Criterion 2377 — A working agent is never reclaimed out from under
  itself.

  Rule: An agent quiet longer than the configured window has its derived state
  reclaimed.

  The failure path that matters most. Reclaiming a live agent's components mid-
  session is worse than never reclaiming at all: the agent keeps working against
  a project that has forgotten what it built.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecLocalWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A live agent keeps what it built" do
    scenario "A working agent is never reclaimed out from under itself" do
      given_ :synced_context_component

      given_ "the agent that built it has been working all along", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/components")

        assert render(view) =~ "ExampleContext",
               "the premise failed: there is no component to keep"

        {:ok, context}
      end

      given_ "another agent is working too", context do
        {:ok, Map.put(context, :live, Fixtures.live_agent_scope(context.scope))}
      end

      when_ "the other agent stops, which syncs components", context do
        hook(context.live, %{"session_id" => "spex-#{System.unique_integer([:positive])}"})
        {:ok, context}
      end

      then_ "the working agent's component is untouched", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/components")

        assert render(view) =~ "ExampleContext",
               "a component belonging to an agent that is still working was " <>
                 "reclaimed. Reclaiming a live agent mid-session is worse than never " <>
                 "reclaiming: it keeps working against a project that has forgotten " <>
                 "what it built, and nothing tells it why."

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
