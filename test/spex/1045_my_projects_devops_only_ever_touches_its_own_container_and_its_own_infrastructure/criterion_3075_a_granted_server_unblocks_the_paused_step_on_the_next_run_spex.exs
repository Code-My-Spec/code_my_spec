defmodule CodeMySpecSpex.Story1045.Criterion3075Spex do
  @moduledoc """
  Story 1045 — My project's devops only ever touches its own container and its own infrastructure
  Criterion 3075 — A granted server unblocks the paused step on the next run.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpec.McpServers.Devops.Tools.{LinkServer, RunProvisioningStep}
  alias CodeMySpec.Provisioning.Hetzner

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Linking a server after a pause lets the next run through" do
    scenario "the first run pauses, and the run after linking proceeds" do
      given_ "Hetzner is connected and the account already owns a server this project can share",
             context do
        CodeMySpecSpex.Fixtures.connect_hetzner(context.scope)

        plug = fn conn ->
          {:ok, _body, conn} = Plug.Conn.read_body(conn)
          reply(conn, conn.method, conn.request_path)
        end

        Req.Test.stub(Hetzner, plug)

        # `EnvironmentRepository.list/1` seeds both prod and uat the first
        # time it is called for a project, but only if neither already has a
        # row. Linking uat below creates just uat's row via `put/3` — if that
        # happened first, the later :server run would find a non-empty list
        # and never seed prod at all, silently dropping it from every
        # environment fan-out this criterion means to exercise.
        CodeMySpecSpex.Fixtures.environments(context.scope)

        {:ok, link_live, _html} = live(context.conn, "/app/servers")

        link_live
        |> element("[data-test='link-server'][phx-value-name='steady-uat-box']")
        |> render_click()

        frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}

        {:reply, _link_response, _frame} =
          LinkServer.execute(%{environment: "uat", server_name: "steady-uat-box"}, frame)

        {:ok, context}
      end

      when_ "the project's devops agent runs the :server step before anything is linked",
            context do
        frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = RunProvisioningStep.execute(%{step: "server"}, frame)
        {:ok, Map.put(context, :first_response, response)}
      end

      when_ "the account agent grants the request by linking the shared server", context do
        {:ok, link_live, _html} = live(context.conn, "/app/servers")

        # steady-uat-box is already linked, so the unlinked section starts
        # collapsed behind "+N more not linked" — expand it before the button
        # for shared-fleet-box is reachable.
        link_live
        |> element("[data-test='unlinked-count']")
        |> render_click()

        link_live
        |> element("[data-test='link-server'][phx-value-name='shared-fleet-box']")
        |> render_click()

        frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}

        {:reply, _link_response, _frame} =
          LinkServer.execute(%{environment: "prod", server_name: "shared-fleet-box"}, frame)

        {:ok, context}
      end

      when_ "the project's devops agent runs the same :server step again", context do
        frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = RunProvisioningStep.execute(%{step: "server"}, frame)
        {:ok, Map.put(context, :second_response, response)}
      end

      then_ "the first run paused and the second proceeded, without repeating a request",
            context do
        assert response_text(context.first_response) =~ "paused",
               "expected the first, unlinked run to pause"

        refute response_text(context.second_response) =~ "paused",
               "expected linking to unblock the step on its next run, not pause it again"

        {:ok, context}
      end
    end
  end

  defp reply(conn, "GET", "/v1/servers") do
    json(conn, %{
      "servers" => [
        %{
          "id" => 1,
          "name" => "shared-fleet-box",
          "status" => "running",
          "location" => %{"name" => "fsn1"},
          "public_net" => %{"ipv4" => %{"ip" => "203.0.113.1"}}
        },
        %{
          "id" => 2,
          "name" => "steady-uat-box",
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
