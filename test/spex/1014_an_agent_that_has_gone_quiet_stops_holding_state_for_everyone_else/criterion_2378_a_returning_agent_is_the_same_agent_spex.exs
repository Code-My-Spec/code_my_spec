defmodule CodeMySpecSpex.Story1014.Criterion2378Spex do
  @moduledoc """
  Story 1014 — Criterion 2378 — A returning agent is the same agent.

  Rule: The harness row survives; only what was derived from it is reclaimed.

  The decision that makes the rest simple. Identity lives in `.cms_harness.json`
  in the checkout, so a returning agent presents the id it always had and resumes
  — no re-mint, no rewrite, no window where the file names a row that does not
  exist.

  Deleting the row would create exactly that window, and the adjacent case is
  already observable: re-onboarding a root whose identity file was removed returns
  a *third* new id rather than resuming, so every offboard/return cycle would leak
  an identity.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecLocalWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Reclaiming takes state, never identity" do
    scenario "A returning agent is the same agent" do
      given_ :synced_context_component

      given_ "that checkout has been quiet for days", context do
        Fixtures.all_agents_go_quiet(context.scope, 96)
        {:ok, Map.put(context, :quiet_id, context.scope.active_harness_id)}
      end

      given_ "another agent is working", context do
        {:ok, Map.put(context, :live, Fixtures.live_agent_scope(context.scope))}
      end

      given_ "the live agent's stop has reclaimed the quiet one's state", context do
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.live.active_harness_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Phoenix.ConnTest.dispatch(@endpoint, :post, "/api/hooks/stop", %{
          "session_id" => "spex-#{System.unique_integer([:positive])}"
        })
        |> Phoenix.ConnTest.json_response(200)

        {:ok, context}
      end

      when_ "the quiet agent comes back, presenting the id from its checkout", context do
        report =
          post_hook(%{active_harness_id: context.quiet_id}, "/api/hooks/stop", %{
            "session_id" => "spex-return-#{System.unique_integer([:positive])}"
          })

        {:ok, Map.put(context, :report, report)}
      end

      then_ "it is served as the same harness", context do
        refute context.report["error"],
               "a returning agent was not recognised. Its identity file names a row " <>
                 "the server no longer has, which is the window keeping the row open " <>
                 "exists to prevent — and re-onboarding a root whose identity file " <>
                 "was removed issues a third id rather than resuming, so every " <>
                 "offboard/return cycle would leak one. Got: #{inspect(context.report)}"

        {:ok, context}
      end
    end
  end
end
