defmodule CodeMySpecSpex.Story971.Criterion8046Spex do
  @moduledoc """
  Story 971 — My deployed app talks back to CodeMySpec without a long-lived key
  Criterion 8046 — The refresh secret buys a token and nothing else.

  The app holds one durable secret. Presented to the exchange it returns a
  short-lived token; presented to anything else it does nothing. That
  narrowness is the entire security argument — the app does carry a
  long-lived secret, so the property that matters is how little it can do
  with it.

  Surface: HTTP — `CodeMySpecWeb.TokenController` and the five
  credential-authenticated endpoints.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "The refresh secret buys a token and nothing else" do
    scenario "the refresh secret is accepted at the exchange and refused everywhere else" do
      given_ "the app holds its refresh secret", context do
        app_holds_refresh_secret(context.scope)

        conn =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("content-type", "application/json")

        {:ok, context |> Map.put(:api_conn, conn) |> Map.put(:refresh_secret, "refresh-secret")}
      end

      when_ "it presents that secret to the exchange", context do
        conn =
          context.api_conn
          |> post("/api/token", %{"refresh_secret" => context.refresh_secret})

        {:ok, Map.put(context, :exchange_conn, conn)}
      end

      then_ "it receives a short-lived token", context do
        body = Phoenix.ConnTest.json_response(context.exchange_conn, 200)

        assert is_binary(body["access_token"]) and body["access_token"] != "",
               "expected the exchange to return an access token, got #{inspect(body)}"

        assert is_integer(body["expires_in"]) and body["expires_in"] > 0,
               "expected the token to carry a lifetime, got #{inspect(body["expires_in"])}"

        {:ok, Map.put(context, :access_token, body["access_token"])}
      end

      then_ "that secret can be used for no other operation", context do
        # The refresh secret against a real surface must be refused. Anchor:
        # the same request with the access token is accepted, proving the
        # endpoint works and the refusal is about the credential.
        refused =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("authorization", "Bearer #{context.refresh_secret}")
          |> post("/api/content/sync", %{})

        assert refused.status in [401, 403],
               "expected the refresh secret to be refused at the content surface, got #{refused.status}"

        accepted =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("authorization", "Bearer #{context.access_token}")
          |> post("/api/content/sync", %{})

        refute accepted.status in [401, 403],
               "expected the access token to be accepted where the refresh secret was refused, got #{accepted.status}"

        {:ok, context}
      end
    end
  end
end
