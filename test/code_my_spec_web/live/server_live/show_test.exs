defmodule CodeMySpecWeb.ServerLive.ShowTest do
  @moduledoc """
  a654ed04: this page used to offer a second, separate action -- pick a
  project, then type an environment name, then submit -- to actually point a
  project's environment at the server. That is gone now: the single
  environment field on `/app/servers` (`ServerLive.FormComponent`) is the
  whole link, so this page only has to show what it produced.
  """
  use CodeMySpecTest.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias CodeMySpec.AccountSecrets
  alias CodeMySpec.Environments
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

  test "the old two-step link form is gone", %{conn: conn} do
    stub_hetzner(server("shared-box"))

    {:ok, view, html} = live(conn, ~p"/app/servers")
    view |> element("[data-test='link-server'][phx-value-name='shared-box']") |> render_click()

    {:ok, _view, html} = live(conn, ~p"/app/servers/shared-box")

    refute html =~ "data-test=\"link-environment-form\"",
           "the detail page still offers a second step to make a link that " <>
             "the single menu on /app/servers already makes"
  end

  test "a project environment linked from the single menu shows here", %{
    conn: conn,
    scope: scope
  } do
    stub_hetzner(server("shared-box"))

    project = CodeMySpec.ProjectsFixtures.project_fixture(scope, name: "Second Project")
    project_scope = %{scope | active_project: project, active_project_id: project.id}
    {:ok, _env} = Environments.put(project_scope, "uat", %{})

    {:ok, view, _html} = live(conn, ~p"/app/servers")
    view |> element("[data-test='link-server'][phx-value-name='shared-box']") |> render_click()

    view
    |> element("[data-test='server'][data-name='shared-box'] [data-test='edit-server']")
    |> render_click()

    view
    |> form("[data-test='server-form']", server: %{environment: "uat"})
    |> render_submit()

    {:ok, _view, html} = live(conn, ~p"/app/servers/shared-box")

    assert html =~ "Second Project"
    assert html =~ "uat"
    assert %{server_id: server_id} = Environments.get(project_scope, "uat")
    refute is_nil(server_id)
  end
end
