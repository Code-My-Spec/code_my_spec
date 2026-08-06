defmodule CodeMySpecSpex.Story971.Criterion8020Spex do
  @moduledoc """
  Story 971 — My deployed app talks back to CodeMySpec without a long-lived key
  Criterion 8020 — Calls keep working across the renewal boundary.

  An app running longer than one credential lifetime still makes successful
  calls, and Sam did nothing to keep it working. Short-lived tokens are only
  acceptable if renewal is invisible; otherwise they trade a security
  problem for an operations problem.

  Surface: HTTP — the token exchange and an authenticated endpoint.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "Calls keep working across the renewal boundary" do
    scenario "a call after one full lifetime succeeds without intervention" do
      given_ "a deployed app has been running longer than one credential lifetime", context do
        app_holds_refresh_secret(context.scope)

        conn =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post("/api/token", %{"refresh_secret" => "refresh-secret"})

        body = Phoenix.ConnTest.json_response(conn, 200)

        {:ok,
         context
         |> Map.put(:first_token, body["access_token"])
         |> Map.put(:expires_in, body["expires_in"])}
      end

      when_ "it calls CodeMySpec after that lifetime has elapsed", context do
        # The app renews on its own: it exchanges again rather than reusing
        # the lapsed token. Sam is not in this loop.
        renewed =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> Plug.Conn.put_req_header(
            "x-spex-clock-advance-seconds",
            to_string(context.expires_in + 60)
          )
          |> post("/api/token", %{"refresh_secret" => "refresh-secret"})

        renewed_body = Phoenix.ConnTest.json_response(renewed, 200)

        conn =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("authorization", "Bearer #{renewed_body["access_token"]}")
          |> post("/api/content/sync", %{})

        {:ok,
         context
         |> Map.put(:conn, conn)
         |> Map.put(:second_token, renewed_body["access_token"])}
      end

      then_ "the call succeeds", context do
        refute context.conn.status in [401, 403],
               "expected the call after renewal to succeed, got #{context.conn.status}"

        {:ok, context}
      end

      then_ "the renewal produced a genuinely new token", context do
        # Anchor: if renewal handed back the same string, nothing actually
        # rotated and expiry would be cosmetic.
        refute context.second_token == context.first_token,
               "expected renewal to issue a new token rather than reissuing the lapsed one"

        {:ok, context}
      end

      then_ "Sam did nothing to keep it working", context do
        # The refresh secret alone drove renewal — no operator action, no
        # redeploy, no re-entry of anything.
        assert is_binary(context.second_token) and context.second_token != "",
               "expected the app to renew unattended using only what it already holds"

        {:ok, context}
      end
    end
  end
end
