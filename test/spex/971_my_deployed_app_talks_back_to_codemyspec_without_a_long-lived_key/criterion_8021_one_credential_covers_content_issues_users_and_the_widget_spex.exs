defmodule CodeMySpecSpex.Story971.Criterion8021Spex do
  @moduledoc """
  Story 971 — My deployed app talks back to CodeMySpec without a long-lived key
  Criterion 8021 — One credential covers content, issues, users and the widget.

  A single exchanged token is accepted by every surface the app calls:
  content pull, framework issue reporting, user provisioning, widget users,
  and the widget socket. Today one durable `deploy_key` authenticates all
  five; the point of this criterion is that consolidation survives the move
  to short-lived tokens rather than fragmenting into five credentials.

  Surface: HTTP — all five credential-authenticated endpoints.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @surfaces [
    {"content sync", :post, "/api/content/sync"},
    {"framework issues", :post, "/api/framework/issues"},
    {"user provisioning", :get, "/api/cms/users"},
    {"widget users", :post, "/api/widget/users"},
    {"widget socket", :get, "/api/widget/socket_token"}
  ]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "One credential covers content, issues, users and the widget" do
    scenario "a single token is accepted by all five surfaces" do
      given_ "a deployed app holds a valid credential", context do
        app_holds_refresh_secret(context.scope)

        conn =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post("/api/token", %{"refresh_secret" => "refresh-secret"})

        body = Phoenix.ConnTest.json_response(conn, 200)

        assert is_binary(body["access_token"]),
               "expected a token to exchange against the surfaces"

        {:ok, Map.put(context, :token, body["access_token"])}
      end

      when_ "it pulls content, reports an issue, provisions a user and opens the widget connection",
            context do
        results =
          Enum.map(@surfaces, fn {name, method, path} ->
            conn =
              Phoenix.ConnTest.build_conn()
              |> Plug.Conn.put_req_header("content-type", "application/json")
              |> Plug.Conn.put_req_header("authorization", "Bearer #{context.token}")

            conn =
              case method do
                :get -> get(conn, path)
                :post -> post(conn, path, %{})
              end

            {name, conn.status}
          end)

        {:ok, Map.put(context, :results, results)}
      end

      then_ "every one of those is accepted on that same credential", context do
        # Anchor: all five surfaces were actually exercised.
        assert length(context.results) == 5,
               "expected all five surfaces to be called, got #{inspect(context.results)}"

        for {name, status} <- context.results do
          refute status in [401, 403],
                 "expected #{name} to accept the shared token, got #{status}"
        end

        {:ok, context}
      end
    end
  end
end
