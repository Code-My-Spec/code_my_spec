defmodule CodeMySpecSpex.Story971.Criterion8019Spex do
  @moduledoc """
  Story 971 — My deployed app talks back to CodeMySpec without a long-lived key
  Criterion 8019 — A captured credential is useless after its window.

  A token captured from a surface stops working once its window passes, and
  no revocation by Sam was required to make that true. Expiry that depends
  on someone noticing and acting is not expiry.

  Time is advanced with the page clock rather than by sleeping, so the spec
  observes real expiry behaviour without a wall-clock wait.

  Surface: HTTP — the credential-authenticated endpoints.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "A captured credential is useless after its window" do
    scenario "an expired token is refused with no revocation step" do
      given_ "someone captured the token the app was using", context do
        app_holds_refresh_secret(context.scope)

        conn =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post("/api/token", %{"refresh_secret" => "refresh-secret"})

        body = Phoenix.ConnTest.json_response(conn, 200)

        # Anchor: the captured token works right now, so the refusal later is
        # about elapsed time and nothing else.
        working =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("authorization", "Bearer #{body["access_token"]}")
          |> post("/api/content/sync", %{})

        refute working.status in [401, 403],
               "expected the freshly captured token to work before its window passes"

        {:ok,
         context
         |> Map.put(:captured, body["access_token"])
         |> Map.put(:expires_in, body["expires_in"])}
      end

      when_ "they try to use it after its window has passed", context do
        conn =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("authorization", "Bearer #{context.captured}")
          |> Plug.Conn.put_req_header(
            "x-spex-clock-advance-seconds",
            to_string(context.expires_in + 60)
          )
          |> post("/api/content/sync", %{})

        {:ok, Map.put(context, :conn, conn)}
      end

      then_ "CodeMySpec refuses it", context do
        assert context.conn.status in [401, 403],
               "expected the expired token to be refused, got #{context.conn.status}"

        {:ok, context}
      end

      then_ "no revocation by Sam was required to make that true", context do
        body = Phoenix.ConnTest.json_response(context.conn, context.conn.status)

        assert body["reason"] == "expired",
               "expected the refusal to be expiry rather than revocation, got #{inspect(body["reason"])}"

        {:ok, context}
      end
    end
  end
end
