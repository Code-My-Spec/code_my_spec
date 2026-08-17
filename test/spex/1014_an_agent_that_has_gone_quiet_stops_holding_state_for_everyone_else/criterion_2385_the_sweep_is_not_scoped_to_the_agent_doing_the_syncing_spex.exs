defmodule CodeMySpecSpex.Story1014.Criterion2385Spex do
  @moduledoc """
  Story 1014 — Criterion 2385 — The sweep is not scoped to the agent doing the
  syncing.

  Rule: Reclaiming happens when components are synced, not on a schedule.

  The easiest way to implement this story and have it do nothing. Every other
  operation in the sync is scoped to the syncing harness — that is the isolation
  the whole file model rests on — so a reclaim written in the same shape inherits
  the scope and sweeps only the agent that is by definition live.

  It would pass a naive test, break nothing, and reclaim nothing forever.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecLocalWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The syncing agent sweeps the others, not itself" do
    scenario "The sweep is not scoped to the agent doing the syncing" do
      given_ :synced_context_component

      given_ "the checkout that built it has gone quiet", context do
        Fixtures.all_agents_go_quiet(context.scope, 96)
        {:ok, context}
      end

      given_ "a different agent is the one still working", context do
        live = Fixtures.live_agent_scope(context.scope)

        refute live.active_harness_id == context.scope.active_harness_id,
               "the premise failed: the live agent is the quiet one, so a " <>
                 "self-scoped sweep would pass by accident"

        {:ok, Map.put(context, :live, live)}
      end

      # Listed to begin with, for the same reason 2384 needs it: the `then_`
      # refutes its presence afterwards, and a page rendering nothing satisfies
      # that whether or not the sweep reclaimed anything.
      given_ "the quiet checkout's component is listed", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/components")

        assert render(view) =~ "ExampleContext",
               "expected the quiet checkout's component to be listed before the sweep"

        {:ok, context}
      end

      when_ "the live agent stops, which syncs components", context do
        hook(context.live, %{"session_id" => "spex-#{System.unique_integer([:positive])}"})
        {:ok, context}
      end

      then_ "the other agent's state is what got reclaimed", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/components")

        refute render(view) =~ "ExampleContext",
               "the sweep reclaimed nothing, which is what a reclaim scoped to the " <>
                 "syncing harness does: that agent is live by definition, so it " <>
                 "sweeps itself and finds nothing every time. Every other operation " <>
                 "in this sync is harness-scoped, so inheriting that scope here is " <>
                 "the natural mistake and the silent one."

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
