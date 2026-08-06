defmodule CodeMySpecSpex.Story971.Criterion8023Spex do
  @moduledoc """
  Story 971 — My deployed app talks back to CodeMySpec without a long-lived key
  Criterion 8023 — A refusal says why, so the app knows to renew.

  An expired token is refused with a reason that distinguishes expiry from a
  bad credential, and the app renews and retries rather than failing
  outright. Without that distinction the client cannot tell "renew" from
  "give up", so it either retries forever on a genuinely bad credential or
  dies on a routine expiry.

  Surface: HTTP — the token exchange and an authenticated endpoint.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "A refusal says why, so the app knows to renew" do
    scenario "expiry and a bad credential are distinguishable, and expiry drives a retry" do
      given_ "the app's credential has expired", context do
        app_holds_refresh_secret(context.scope)

        conn =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post("/api/token", %{"refresh_secret" => "refresh-secret"})

        body = Phoenix.ConnTest.json_response(conn, 200)

        {:ok,
         context
         |> Map.put(:token, body["access_token"])
         |> Map.put(:expires_in, body["expires_in"])}
      end

      when_ "it calls CodeMySpec", context do
        expired =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("authorization", "Bearer #{context.token}")
          |> Plug.Conn.put_req_header(
            "x-spex-clock-advance-seconds",
            to_string(context.expires_in + 60)
          )
          |> post("/api/content/sync", %{})

        bogus =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("authorization", "Bearer not-a-real-token")
          |> post("/api/content/sync", %{})

        {:ok, context |> Map.put(:expired, expired) |> Map.put(:bogus, bogus)}
      end

      then_ "it is refused with a reason distinguishing expiry from a bad credential", context do
        expired_body = Phoenix.ConnTest.json_response(context.expired, context.expired.status)
        bogus_body = Phoenix.ConnTest.json_response(context.bogus, context.bogus.status)

        assert expired_body["reason"] == "expired",
               "expected an expiry reason, got #{inspect(expired_body["reason"])}"

        assert bogus_body["reason"] == "invalid",
               "expected a distinct reason for a bad credential, got #{inspect(bogus_body["reason"])}"

        refute expired_body["reason"] == bogus_body["reason"],
               "expected expiry and invalidity to be distinguishable so the client can decide whether to renew"

        {:ok, context}
      end

      then_ "it renews and retries rather than failing outright", context do
        renewed =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post("/api/token", %{"refresh_secret" => "refresh-secret"})

        body = Phoenix.ConnTest.json_response(renewed, 200)

        retried =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("authorization", "Bearer #{body["access_token"]}")
          |> post("/api/content/sync", %{})

        refute retried.status in [401, 403],
               "expected the retry after renewal to succeed, got #{retried.status}"

        {:ok, context}
      end
    end
  end
end
