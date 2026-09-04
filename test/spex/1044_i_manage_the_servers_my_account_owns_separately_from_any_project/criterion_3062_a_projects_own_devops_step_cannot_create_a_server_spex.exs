defmodule CodeMySpecSpex.Story1044.Criterion3062Spex do
  @moduledoc """
  Story 1044 — I manage the servers my account owns, separately from any project
  Criterion 3062 — A project's own devops step cannot create a server.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.McpServers.Devops.Tools.RunProvisioningStep
  alias CodeMySpec.Provisioning.Hetzner

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The project's own :server step refuses to create infrastructure nobody linked" do
    scenario "an unlinked environment's server step never asks the provider to create anything" do
      given_ "Hetzner is connected but this project has never linked a server", context do
        CodeMySpecSpex.Fixtures.connect_hetzner(context.scope)
        test_pid = self()

        plug = fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          payload = if body == "", do: %{}, else: Jason.decode!(body)

          if conn.method == "POST" and conn.request_path == "/v1/servers" do
            send(test_pid, {:server_creation_attempted, payload["name"]})
          end

          reply(conn, conn.method, conn.request_path)
        end

        Req.Test.stub(Hetzner, plug)
        {:ok, context}
      end

      when_ "the project's devops agent runs the :server step through the real MCP tool",
            context do
        frame = %Anubis.Server.Frame{
          assigns: %{current_scope: %{context.scope | environment: context.environment}}
        }

        {:reply, response, _frame} = RunProvisioningStep.execute(%{step: "server"}, frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the provider is never asked to create a server", context do
        refute_received {:server_creation_attempted, _name},
                         "the :server step must not reach the provider's create-server path " <>
                           "for an environment nothing has linked"

        {:ok, context}
      end

      then_ "the response says the step is waiting, not that it succeeded", context do
        text = response_text(context.response)
        assert text =~ "paused", "expected the step to report itself paused, got: #{text}"

        {:ok, context}
      end
    end
  end

  defp reply(conn, "GET", "/v1/servers"), do: json(conn, %{"servers" => []})
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
