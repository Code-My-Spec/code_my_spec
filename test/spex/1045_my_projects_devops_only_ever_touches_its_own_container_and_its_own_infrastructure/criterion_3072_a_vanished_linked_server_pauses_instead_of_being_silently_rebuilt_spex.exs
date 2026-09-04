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
  # Reaching the registry step for real needs a fake shell, not a real one —
  # the network is adopted correctly now (this criterion's servers carry a
  # `private_net`, since that read happens before the gate this spec is
  # actually about), so without this the run would go on to open a real SSH
  # connection to a TEST-NET address and hang.
  setup :fake_working_directory

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

        # Reaching the registry's own "is it running" check (refused, since
        # nothing here brought the shared container up — that is the
        # account's job, not this spec's) proves both servers were found and
        # adopted while still present — the first half of this criterion.
        # Actually bringing the registry up needs the account-level tool
        # (`Fixtures.bootstrap_account_server/3`), a different criterion's
        # concern.
        assert first_text =~ "not provisioned",
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
      "public_net" => %{"ipv4" => %{"ip" => "203.0.113.2"}},
      "private_net" => [%{"network" => 99, "ip" => "10.0.0.2"}]
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
              "public_net" => %{"ipv4" => %{"ip" => "203.0.113.1"}},
              "private_net" => [%{"network" => 99, "ip" => "10.0.0.1"}]
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

  # Populated — the network is account infrastructure now
  # (`provision_account_server/3`'s job), already there by the time a
  # project's own `:server` step ever reaches a linked server.
  defp reply(conn, "GET", "/v1/networks", _state) do
    json(conn, %{
      "networks" => [
        %{"id" => 99, "name" => "shared", "ip_range" => "10.0.0.0/16", "subnets" => []}
      ]
    })
  end
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
