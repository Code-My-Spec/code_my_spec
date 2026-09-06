defmodule CodeMySpecWeb.ServerLive.ShowTest do
  @moduledoc """
  Before this, the only way to point a project's environment at a server was
  `link_server`, the devops MCP tool — nothing on `/app/servers` could make
  that connection at all. Confirmed live: the `:server` step's own pause
  message says "link one of those" with no page for Sam to go do it on.
  """
  use CodeMySpecTest.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias CodeMySpec.AccountSecrets
  alias CodeMySpec.Provisioning.EnvironmentRepository
  alias CodeMySpec.Provisioning.Hetzner

  setup [:register_log_in_setup_account]

  setup %{scope: scope} do
    AccountSecrets.put_value(scope, "hetzner_api_token", "test-token")
    :ok
  end

  defp stub_hetzner(server) do
    Req.Test.stub(Hetzner, fn
      %{method: "GET", request_path: "/v1/servers"} = conn ->
        json(conn, 200, %{"servers" => [server]})

      %{method: "GET", request_path: "/v1/firewalls"} = conn ->
        json(conn, 200, %{"firewalls" => []})

      %{method: "GET", request_path: "/v1/datacenters"} = conn ->
        json(conn, 200, %{"datacenters" => []})

      %{method: "GET", request_path: "/v1/server_types"} = conn ->
        json(conn, 200, %{"server_types" => []})
    end)
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp server(name, id \\ 1),
    do: %{
      "id" => id,
      "name" => name,
      "status" => "running",
      "public_net" => %{"ipv4" => %{"ip" => "10.0.0.1"}},
      "server_type" => %{"name" => "cpx11"}
    }

  test "linking a project's environment writes the server onto it", %{conn: conn, scope: scope} do
    stub_hetzner(server("shared-box"))

    {:ok, view, html} = live(conn, ~p"/app/servers")
    assert html =~ "shared-box"

    view |> element("[data-test='link-server'][phx-value-name='shared-box']") |> render_click()

    other_project = CodeMySpec.ProjectsFixtures.project_fixture(scope, name: "Second Project")

    {:ok, view, html} = live(conn, ~p"/app/servers/shared-box")
    refute html =~ "Second Project (uat)"

    view
    |> form("[data-test='link-environment-form']", %{project_id: other_project.id})
    |> render_change()

    html =
      view
      |> form("[data-test='link-environment-form']", %{
        project_id: other_project.id,
        environment: "uat"
      })
      |> render_submit()

    assert html =~ "Second Project"
    assert html =~ "uat"

    project_scope = %{scope | active_project: other_project, active_project_id: other_project.id}
    assert %{server_id: server_id} = EnvironmentRepository.get(project_scope, "uat")
    refute is_nil(server_id)
  end
end
