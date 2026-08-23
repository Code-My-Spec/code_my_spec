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

  ## Two things this used to leave unchecked (issue `214d8050`)

  Its only assertion was `refute report["error"]`, and both halves of that were
  weaker than they read.

  The premise never showed the reclaim happened. "The live agent's stop has
  reclaimed the quiet one's state" posted a stop and asserted nothing about it,
  so a reclaim that silently did nothing left the criterion asking whether
  identity survives an event that never occurred — which it trivially does. The
  component the quiet checkout built is now read off the components page before
  and after, the way sibling 2384 reads it, so the sweep is observed rather than
  assumed.

  And the refute could not see its own failure. An unrecognised id is refused by
  `HarnessScope` with **404**, not a 200 carrying an error key, so `post_hook`'s
  `json_response(200)` would raise before the refute ran — failing the criterion,
  but with a message about a status code instead of the words written here about
  leaked identities. Meanwhile `Stop.decide` has no `"error"` key to emit on the
  success path, so against any 200 the refute holds no matter what came back. The
  status is now asserted directly, which is the thing that actually distinguishes
  a served agent from a stranger.
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
        {:ok, Map.put(context, :quiet_id, context.scope.active_working_copy_id)}
      end

      given_ "another agent is working", context do
        {:ok, Map.put(context, :live, Fixtures.live_agent_scope(context.scope))}
      end

      given_ "the quiet checkout's component is listed", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/components")

        assert render(view) =~ "ExampleContext",
               "expected the quiet checkout's component to be listed before the " <>
                 "sweep — without it there is no reclaim for the return to survive"

        {:ok, context}
      end

      given_ "the live agent's stop has reclaimed the quiet one's state", context do
        post_hook(context.live, "/api/hooks/stop", %{
          "session_id" => "spex-#{System.unique_integer([:positive])}"
        })

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/components")

        refute render(view) =~ "ExampleContext",
               "the live agent's stop reclaimed nothing, so this criterion would " <>
                 "ask whether identity survives an event that did not happen"

        {:ok, context}
      end

      # Dispatched rather than `post_hook`ed, because the failure this criterion
      # exists to catch is a 404 from `HarnessScope` — and `post_hook` asserts a
      # 200 on the way in, so it would raise there and the message below would
      # never print.
      when_ "the quiet agent comes back, presenting the id from its checkout", context do
        conn =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.quiet_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> Phoenix.ConnTest.dispatch(@endpoint, :post, "/api/hooks/stop", %{
            "session_id" => "spex-return-#{System.unique_integer([:positive])}"
          })

        {:ok, Map.put(context, :return, conn)}
      end

      then_ "it is served as the same harness", context do
        assert context.return.status == 200,
               "a returning agent was not recognised — HarnessScope refused the id " <>
                 "its checkout has always presented (#{context.return.status}). Its " <>
                 "identity file names a row the server no longer has, which is the " <>
                 "window keeping the row open exists to prevent: re-onboarding a root " <>
                 "whose identity file was removed issues a third id rather than " <>
                 "resuming, so every offboard/return cycle would leak one. Body: " <>
                 context.return.resp_body

        refute Jason.decode!(context.return.resp_body)["error"],
               "served, but with an error: #{context.return.resp_body}"

        {:ok, context}
      end
    end
  end
end
