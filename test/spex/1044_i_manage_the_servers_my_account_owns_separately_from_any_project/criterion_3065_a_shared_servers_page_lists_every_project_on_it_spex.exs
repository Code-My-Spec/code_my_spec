defmodule CodeMySpecSpex.Story1044.Criterion3065Spex do
  @moduledoc """
  Story 1044 — I manage the servers my account owns, separately from any project
  Criterion 3065 — A shared server's page lists every project on it.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpec.McpServers.Devops.Tools.LinkServer
  alias CodeMySpec.Provisioning.Hetzner

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A shared server's page names every project deployed onto it" do
    scenario "two different projects, both pointed at the same server, both show up" do
      given_ "the account has one server, and Sam has already linked it", context do
        CodeMySpecSpex.Fixtures.connect_hetzner(context.scope)

        plug = fn conn ->
          {:ok, _body, conn} = Plug.Conn.read_body(conn)
          reply(conn, conn.method, conn.request_path)
        end

        Req.Test.stub(Hetzner, plug)

        {:ok, servers_live, _html} = live(context.conn, "/app/servers")

        servers_live
        |> element("[data-test='link-server'][phx-value-name='shared-box']")
        |> render_click()

        {:ok, context}
      end

      given_ "a second project exists in the same account", context do
        second =
          CodeMySpecSpex.Fixtures.project_fixture_unlinked(context.scope, %{
            name: "second-project"
          })

        {:ok, Map.put(context, :second_project, second)}
      end

      when_ "the first project's prod environment is pointed at the shared server", context do
        frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}

        {:reply, _response, _frame} =
          LinkServer.execute(%{environment: "prod", server_name: "shared-box"}, frame)

        {:ok, context}
      end

      when_ "the second project's prod environment is also pointed at the shared server",
            context do
        second_scope = %{
          context.scope
          | active_project: context.second_project,
            active_project_id: context.second_project.id
        }

        frame = %Anubis.Server.Frame{assigns: %{current_scope: second_scope}}

        {:reply, _response, _frame} =
          LinkServer.execute(%{environment: "prod", server_name: "shared-box"}, frame)

        {:ok, context}
      end

      then_ "the server's own page names both projects", context do
        {:ok, show_live, html} = live(context.conn, "/app/servers/shared-box")

        assert html =~ context.project.name,
               "expected the first project to be named on its shared server's page"

        assert html =~ context.second_project.name,
               "expected the second project to be named on its shared server's page too"

        {:ok, Map.put(context, :show_live, show_live)}
      end
    end
  end

  defp reply(conn, "GET", "/v1/servers") do
    json(conn, %{
      "servers" => [
        %{
          "id" => 1,
          "name" => "shared-box",
          "status" => "running",
          "location" => %{"name" => "fsn1"},
          "public_net" => %{"ipv4" => %{"ip" => "203.0.113.1"}}
        }
      ]
    })
  end

  defp reply(conn, _method, _path), do: json(conn, %{})

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(201, Jason.encode!(body))
  end
end
