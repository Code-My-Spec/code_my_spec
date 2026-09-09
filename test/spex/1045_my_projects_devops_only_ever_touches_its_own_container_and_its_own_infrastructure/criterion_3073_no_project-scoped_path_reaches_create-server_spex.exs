defmodule CodeMySpecSpex.Story1045.Criterion3073Spex do
  @moduledoc """
  Story 1045 — My project's devops only ever touches its own container and its own infrastructure
  Criterion 3073 — No project-scoped path reaches create-server.

  Broader than criterion 3070/3071 (which cover run_provisioning_step's
  :server step alone): this drives both project-scoped devops entry points —
  the single-step tool and the whole-sequence tool — since either could
  reach create-server if only one were gated.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.McpServers.Devops.Tools.{RunDevopsSetup, RunProvisioningStep}
  alias CodeMySpec.Provisioning.Hetzner

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Neither project-scoped devops entry point can create a server" do
    scenario "running a single step, then the whole sequence, creates nothing at the provider" do
      given_ "Hetzner is connected and this project has no linked server", context do
        CodeMySpecSpex.Fixtures.connect_hetzner(context.scope)
        test_pid = self()

        plug = fn conn ->
          {:ok, _body, conn} = Plug.Conn.read_body(conn)

          CodeMySpecSpex.Fixtures.notify_server_create(
            test_pid,
            conn.method,
            conn.request_path,
            :server_created
          )

          reply(conn, conn.method, conn.request_path)
        end

        Req.Test.stub(Hetzner, plug)
        {:ok, context}
      end

      when_ "the project's devops agent runs the single :server step", context do
        frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}
        {:reply, _response, _frame} = RunProvisioningStep.execute(%{step: "server"}, frame)
        {:ok, context}
      end

      when_ "it also runs the whole devops setup sequence", context do
        frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}
        {:reply, _response, _frame} = RunDevopsSetup.execute(%{}, frame)
        {:ok, context}
      end

      then_ "the provider was never asked to create a server through either path", context do
        refute_received :server_created,
                        "a project-scoped devops entry point reached the provider's " <>
                          "create-server path for an unlinked environment"

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
