defmodule CodeMySpecSpex.Story1045.Criterion3071Spex do
  @moduledoc """
  Story 1045 — My project's devops only ever touches its own container and its own infrastructure
  Criterion 3071 — Broken_oaths-style duplicate creation no longer happens.

  Names the actual incident: an unlinked environment's :server step guessed a
  name and created a brand-new dedicated server instead of sharing the
  account's existing infrastructure. This proves the provider is never even
  asked to create one, not just that the reply says "paused".
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.McpServers.Devops.Tools.RunProvisioningStep
  alias CodeMySpec.Provisioning.Hetzner

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An unlinked environment never causes a new dedicated server to be created" do
    scenario "the provider's create-server endpoint is never called" do
      given_ "Hetzner is connected, the account already owns a shared server, and this project has never linked to it",
             context do
        CodeMySpecSpex.Fixtures.connect_hetzner(context.scope)
        test_pid = self()

        plug = fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          payload = if body == "", do: %{}, else: Jason.decode!(body)

          if conn.method == "POST" and conn.request_path == "/v1/servers" do
            send(test_pid, {:server_created, payload["name"]})
          end

          reply(conn, conn.method, conn.request_path)
        end

        Req.Test.stub(Hetzner, plug)
        {:ok, context}
      end

      when_ "the project's own devops setup runs its :server step", context do
        frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}
        {:reply, _response, _frame} = RunProvisioningStep.execute(%{step: "server"}, frame)
        {:ok, context}
      end

      then_ "no server was ever created on the provider", context do
        refute_received {:server_created, _name},
                         "a dedicated server was created for an unlinked environment — this " <>
                           "is exactly the broken_oaths incident this story exists to close"

        {:ok, context}
      end
    end
  end

  defp reply(conn, "GET", "/v1/servers") do
    json(conn, %{
      "servers" => [
        %{
          "id" => 1,
          "name" => "fuellytics-prod",
          "status" => "running",
          "location" => %{"name" => "fsn1"},
          "public_net" => %{"ipv4" => %{"ip" => "203.0.113.1"}}
        }
      ]
    })
  end

  defp reply(conn, "GET", "/v1/firewalls"), do: json(conn, %{"firewalls" => []})
  defp reply(conn, "GET", "/v1/ssh_keys"), do: json(conn, %{"ssh_keys" => []})
  defp reply(conn, "GET", "/v1/networks"), do: json(conn, %{"networks" => []})

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
