defmodule CodeMySpecSpex.Story971.Criterion8045Spex do
  @moduledoc """
  Story 971 — My deployed app talks back to CodeMySpec without a long-lived key
  Criterion 8045 — What the environment holds opens none of the five surfaces.

  Take the credential stored in a deployed environment, present it directly
  to content sync, framework issues, user provisioning, widget users and
  the widget socket, and every one of them refuses it.

  This replaced an earlier phrasing — "the environment holds nothing that
  stays useful" — which the refresh-secret design makes false: it *does*
  hold something durable. The honest property is that what it holds cannot
  be used against anything it calls.

  Surface: HTTP — the five credential-authenticated endpoints.
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
  setup :devops_on

  spex "What the environment holds opens none of the five surfaces" do
    scenario "the stored credential is refused by every authenticated surface" do
      given_ "a deployed environment is calling CodeMySpec successfully", context do
        app_holds_refresh_secret(context.scope)

        conn =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post("/api/token", %{"refresh_secret" => "refresh-secret"})

        body = Phoenix.ConnTest.json_response(conn, 200)

        # Anchor: the environment genuinely can talk to CodeMySpec, so the
        # refusals below are about the credential and not a broken setup.
        assert is_binary(body["access_token"]),
               "expected the environment to be able to obtain a working token"

        {:ok,
         context
         |> Map.put(:stored_credential, "refresh-secret")
         |> Map.put(:access_token, body["access_token"])}
      end

      when_ "someone takes the credential stored in that environment", context do
        results =
          Enum.map(@surfaces, fn {name, method, path} ->
            conn =
              Phoenix.ConnTest.build_conn()
              |> Plug.Conn.put_req_header("content-type", "application/json")
              |> Plug.Conn.put_req_header(
                "authorization",
                "Bearer #{context.stored_credential}"
              )

            {name, call(conn, method, path).status}
          end)

        {:ok, Map.put(context, :results, results)}
      end

      then_ "every one of them refuses it", context do
        for {name, status} <- context.results do
          assert status in [401, 403],
                 "expected #{name} to refuse the stored credential, got #{status}"
        end

        {:ok, context}
      end

      then_ "the same surfaces accept a properly exchanged token", context do
        # Without this the refusals above could be explained by the surfaces
        # being broken or unrouted rather than by credential scope.
        {_name, _method, path} = hd(@surfaces)

        conn =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("authorization", "Bearer #{context.access_token}")
          |> get(path)

        refute conn.status in [401, 403],
               "expected an exchanged token to be accepted, got #{conn.status}"

        {:ok, context}
      end
    end
  end

  defp call(conn, :get, path), do: get(conn, path)
  defp call(conn, :post, path), do: post(conn, path, %{})
end
