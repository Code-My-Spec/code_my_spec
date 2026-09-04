defmodule CodeMySpecSpex.Story1045.Criterion3074Spex do
  @moduledoc """
  Story 1045 — My project's devops only ever touches its own container and its own infrastructure
  Criterion 3074 — A fully-linked project's devops run is unchanged.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpec.McpServers.Devops.Tools.{LinkServer, RunProvisioningStep}
  alias CodeMySpec.Provisioning.Hetzner

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A project whose environments are already linked behaves exactly as before" do
    scenario "the :server step finds the linked server and proceeds, no pause" do
      given_ "the project's prod environment is already linked to an existing server",
             context do
        CodeMySpecSpex.Fixtures.connect_hetzner(context.scope)

        plug = fn conn ->
          {:ok, _body, conn} = Plug.Conn.read_body(conn)
          reply(conn, conn.method, conn.request_path)
        end

        Req.Test.stub(Hetzner, plug)

        {:ok, link_live, _html} = live(context.conn, "/app/servers")

        link_live
        |> element("[data-test='link-server'][phx-value-name='already-there-box']")
        |> render_click()

        link_live
        |> element("[data-test='link-server'][phx-value-name='already-there-uat-box']")
        |> render_click()

        frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}

        {:reply, _link_response, _frame} =
          LinkServer.execute(%{environment: "prod", server_name: "already-there-box"}, frame)

        {:reply, _link_response, _frame} =
          LinkServer.execute(%{environment: "uat", server_name: "already-there-uat-box"}, frame)

        {:ok, context}
      end

      when_ "the project's devops agent runs the :server step", context do
        frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = RunProvisioningStep.execute(%{step: "server"}, frame)
        {:ok, Map.put(context, :response, response)}
      end

      then_ "the step finds both already-linked servers instead of pausing", context do
        text = response_text(context.response)

        refute text =~ "paused",
               "a fully-linked environment must not pause the same way an unlinked one does"

        refute text =~ "does not have",
               "expected both already-linked servers to be found on the provider, not reported missing"

        # The run gets exactly as far as the registry step, which wants a
        # private-network address this stub does not simulate — reaching it
        # proves the already-linked server was found and adopted rather than
        # treated as needing a new one, which is this criterion's subject. A
        # working registry needs a real SSH-reachable box (see
        # `CodeMySpecSpex.Case.fleet_box/1`), which is a different criterion's
        # concern.
        assert text =~ "no private address",
               "expected the already-linked servers to be found and adopted, not paused or missing"

        {:ok, context}
      end
    end
  end

  defp reply(conn, "GET", "/v1/servers") do
    json(conn, %{
      "servers" => [
        %{
          "id" => 1,
          "name" => "already-there-box",
          "status" => "running",
          "location" => %{"name" => "fsn1"},
          "public_net" => %{"ipv4" => %{"ip" => "203.0.113.1"}}
        },
        %{
          "id" => 2,
          "name" => "already-there-uat-box",
          "status" => "running",
          "location" => %{"name" => "fsn1"},
          "public_net" => %{"ipv4" => %{"ip" => "203.0.113.2"}}
        }
      ]
    })
  end

  defp reply(conn, "GET", "/v1/firewalls"), do: json(conn, %{"firewalls" => []})
  defp reply(conn, "GET", "/v1/ssh_keys"), do: json(conn, %{"ssh_keys" => []})
  defp reply(conn, "GET", "/v1/networks"), do: json(conn, %{"networks" => []})
  defp reply(conn, "GET", "/v1/datacenters"), do: json(conn, %{"datacenters" => []})
  defp reply(conn, "GET", "/v1/server_types"), do: json(conn, %{"server_types" => []})

  defp reply(conn, "POST", "/v1/ssh_keys") do
    json(conn, %{"ssh_key" => %{"id" => 1, "fingerprint" => "aa:bb"}})
  end

  defp reply(conn, _method, _path), do: json(conn, %{"network" => %{"id" => 1, "name" => "net"}})

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(201, Jason.encode!(body))
  end
end
