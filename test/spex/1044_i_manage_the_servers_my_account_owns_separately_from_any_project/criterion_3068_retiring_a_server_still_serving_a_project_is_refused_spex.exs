defmodule CodeMySpecSpex.Story1044.Criterion3068Spex do
  @moduledoc """
  Story 1044 — I manage the servers my account owns, separately from any project
  Criterion 3068 — Retiring a server still serving a project is refused.

  No retire action exists on `ServerLive.Index` yet — this drives the
  `data-test="retire-server"` control the account-level page's lifecycle
  (criterion 3063) already needs, so this fails for the true reason (the
  control does not exist yet) rather than a reason invented to pass today.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpec.McpServers.Devops.Tools.LinkServer
  alias CodeMySpec.Provisioning.Hetzner

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A server still serving a project cannot be retired" do
    scenario "Sam tries to retire a linked, still-in-use server" do
      given_ "the account's one server is linked and serves this project's prod environment",
             context do
        CodeMySpecSpex.Fixtures.connect_hetzner(context.scope)

        plug = fn conn ->
          {:ok, _body, conn} = Plug.Conn.read_body(conn)
          reply(conn, conn.method, conn.request_path)
        end

        Req.Test.stub(Hetzner, plug)

        {:ok, link_live, _html} = live(context.conn, "/app/servers")

        link_live
        |> element("[data-test='link-server'][phx-value-name='in-use-box']")
        |> render_click()

        frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}

        {:reply, _response, _frame} =
          LinkServer.execute(%{environment: "prod", server_name: "in-use-box"}, frame)

        {:ok, context}
      end

      when_ "Sam tries to retire it from the account-level page", context do
        {:ok, servers_live, _html} = live(context.conn, "/app/servers/in-use-box")

        servers_live
        |> element("[data-test='retire-server']")
        |> render_click()

        {:ok, Map.put(context, :servers_live, servers_live)}
      end

      then_ "the retirement is refused, naming this project as the reason", context do
        html = render(context.servers_live)

        assert has_element?(context.servers_live, "[data-test='retire-error']"),
               "expected a refusal to render when retiring a server still in use"

        assert html =~ context.project.name,
               "the refusal should name the project still depending on this server"

        {:ok, context}
      end
    end
  end

  defp reply(conn, "GET", "/v1/servers") do
    json(conn, %{
      "servers" => [
        %{
          "id" => 1,
          "name" => "in-use-box",
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
