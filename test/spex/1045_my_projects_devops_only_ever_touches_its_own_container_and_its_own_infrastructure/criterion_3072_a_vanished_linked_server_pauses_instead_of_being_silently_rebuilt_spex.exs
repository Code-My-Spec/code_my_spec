defmodule CodeMySpecSpex.Story1045.Criterion3072Spex do
  @moduledoc """
  Story 1045 — My project's devops only ever touches its own container and its own infrastructure
  Criterion 3072 — A vanished linked server pauses instead of being silently rebuilt.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpec.McpServers.Devops.Tools.{LinkServer, RunProvisioningStep}
  alias CodeMySpec.Provisioning.Hetzner

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A linked server that has vanished from the provider is not silently rebuilt" do
    scenario "the environment's server step pauses rather than recreating it under a guessed name" do
      given_ "the project's prod environment is linked to a server that once existed",
             context do
        CodeMySpecSpex.Fixtures.connect_hetzner(context.scope)
        {:ok, state} = Agent.start_link(fn -> true end)

        plug = fn conn ->
          {:ok, _body, conn} = Plug.Conn.read_body(conn)
          reply(conn, conn.method, conn.request_path, state)
        end

        Req.Test.stub(Hetzner, plug)

        {:ok, link_live, _html} = live(context.conn, "/app/servers")

        link_live
        |> element("[data-test='link-server'][phx-value-name='now-gone-box']")
        |> render_click()

        link_live
        |> element("[data-test='link-server'][phx-value-name='steady-uat-box']")
        |> render_click()

        frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}

        {:reply, _link_response, _frame} =
          LinkServer.execute(%{environment: "prod", server_name: "now-gone-box"}, frame)

        {:reply, _link_response, _frame} =
          LinkServer.execute(%{environment: "uat", server_name: "steady-uat-box"}, frame)

        {:reply, first_response, _frame} = RunProvisioningStep.execute(%{step: "server"}, frame)

        {:ok, context |> Map.put(:first_response, first_response) |> Map.put(:hetzner_state, state)}
      end

      when_ "the box is destroyed at the provider, and the step runs again", context do
        Agent.update(context.hetzner_state, fn _ -> false end)

        frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = RunProvisioningStep.execute(%{step: "server"}, frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the step pauses instead of creating a replacement under a guessed name", context do
        first_text = response_text(context.first_response)

        refute first_text =~ "paused",
               "expected the linked server to be found and adopted the first time, not paused"

        # Reaching the registry step (which wants a private-network address
        # this stub does not simulate) proves both servers were found and
        # adopted while still present — the first half of this criterion.
        # Completing registry setup for real needs an SSH-reachable box; see
        # `CodeMySpecSpex.Case.fleet_box/1`.
        assert first_text =~ "no private address",
               "expected the linked server to be found and adopted the first time"

        assert response_text(context.response) =~ "paused",
               "expected the vanished linked server to pause the step, not rebuild it"

        {:ok, context}
      end
    end
  end

  defp reply(conn, "GET", "/v1/servers", state) do
    steady_uat_box = %{
      "id" => 2,
      "name" => "steady-uat-box",
      "status" => "running",
      "location" => %{"name" => "fsn1"},
      "public_net" => %{"ipv4" => %{"ip" => "203.0.113.2"}}
    }

    case Agent.get(state, & &1) do
      true ->
        json(conn, %{
          "servers" => [
            %{
              "id" => 1,
              "name" => "now-gone-box",
              "status" => "running",
              "location" => %{"name" => "fsn1"},
              "public_net" => %{"ipv4" => %{"ip" => "203.0.113.1"}}
            },
            steady_uat_box
          ]
        })

      false ->
        json(conn, %{"servers" => [steady_uat_box]})
    end
  end

  defp reply(conn, "GET", "/v1/firewalls", _state), do: json(conn, %{"firewalls" => []})
  defp reply(conn, "GET", "/v1/ssh_keys", _state), do: json(conn, %{"ssh_keys" => []})
  defp reply(conn, "GET", "/v1/networks", _state), do: json(conn, %{"networks" => []})
  defp reply(conn, "GET", "/v1/datacenters", _state), do: json(conn, %{"datacenters" => []})
  defp reply(conn, "GET", "/v1/server_types", _state), do: json(conn, %{"server_types" => []})

  defp reply(conn, "POST", "/v1/ssh_keys", _state) do
    json(conn, %{"ssh_key" => %{"id" => 1, "fingerprint" => "aa:bb"}})
  end

  defp reply(conn, _method, _path, _state), do: json(conn, %{"network" => %{"id" => 1, "name" => "net"}})

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(201, Jason.encode!(body))
  end
end
