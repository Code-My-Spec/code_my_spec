defmodule CodeMySpecSpex.Story1045.Criterion3070Spex do
  @moduledoc """
  Story 1045 — My project's devops only ever touches its own container and its own infrastructure
  Criterion 3070 — An unlinked environment pauses the server step.
  """

  use CodeMySpecSpex.Case, async: true

  alias CodeMySpec.McpServers.Devops.Tools.RunProvisioningStep
  alias CodeMySpec.Provisioning.Hetzner

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The :server step pauses instead of creating for an unlinked environment" do
    scenario "running the step for a project with no linked server pauses it" do
      given_ "Hetzner is connected and this project has never linked a server", context do
        CodeMySpecSpex.Fixtures.connect_hetzner(context.scope)

        plug = fn conn ->
          {:ok, _body, conn} = Plug.Conn.read_body(conn)
          reply(conn, conn.method, conn.request_path)
        end

        Req.Test.stub(Hetzner, plug)
        {:ok, context}
      end

      when_ "the project's devops agent runs the :server step", context do
        frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = RunProvisioningStep.execute(%{step: "server"}, frame)
        {:ok, Map.put(context, :response, response)}
      end

      then_ "the step reports itself paused, not done or errored", context do
        assert response_text(context.response) =~ "paused",
               "expected the :server step to pause for an unlinked environment"

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
