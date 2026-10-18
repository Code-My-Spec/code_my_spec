defmodule CodeMySpecWeb.ServerLive.IndexTest do
  @moduledoc """
  a654ed04: setting what a server is for used to be a free label with no
  effect on any project, while the real link lived on a separate page. Sam
  set `fuellytics -> uat` here, read it as done, and the project's `uat`
  environment still had no `server_id` pointed at the box.

  Now the single environment field on this form IS the link: naming an
  environment that matches an unlinked one anywhere in the account points it
  at this server, and the list shows the real link, not just the label.
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

  defp link_and_edit(view, name) do
    view |> element("[data-test='link-server'][phx-value-name='#{name}']") |> render_click()

    view
    |> element("[data-test='server'][data-name='#{name}'] [data-test='edit-server']")
    |> render_click()
  end

  # "prod"/"uat" are offered as select options and can be submitted directly;
  # anything else has to go through the same "Other…" escape hatch a real
  # browser would (criterion 817) — the select refuses a value with no
  # matching option, same as it would for a human picking from it.
  defp save_environment(view, environment) when environment in ["prod", "uat", ""] do
    view
    |> form("[data-test='server-form']", server: %{environment: environment})
    |> render_submit()
  end

  defp save_environment(view, environment) do
    view
    |> form("[data-test='server-form']", server: %{environment: "__other__"})
    |> render_change()

    view
    |> form("[data-test='server-form']", server: %{custom: environment})
    |> render_submit()
  end

  defp project_scope(scope, project),
    do: %{scope | active_project: project, active_project_id: project.id}

  # The real-link assertion, decoupled from how soon the display catches up:
  # a fresh mount reads the servers list exactly as the next person to open
  # the page would, so it cannot pass on stale data the way asserting on
  # `render_submit`'s own return might.
  defp reload(conn), do: conn |> live(~p"/app/servers") |> elem(2)

  test "choosing an environment that matches an unlinked project environment links it", %{
    conn: conn,
    scope: scope
  } do
    stub_hetzner(server("fuellytics-prod"))

    project = CodeMySpec.ProjectsFixtures.project_fixture(scope, name: "Metric Flow")
    project_scope = project_scope(scope, project)
    {:ok, _env} = EnvironmentRepository.put(project_scope, "prod", %{})
    assert %{server_id: nil} = EnvironmentRepository.get(project_scope, "prod")

    {:ok, view, _html} = live(conn, ~p"/app/servers")
    link_and_edit(view, "fuellytics-prod")
    save_environment(view, "prod")

    assert %{server_id: server_id} = EnvironmentRepository.get(project_scope, "prod")
    refute is_nil(server_id)

    html = reload(conn)
    assert html =~ "Metric Flow / prod"
    refute html =~ "not used by any project"
  end

  test "the list shows real links only, and says so when there are none", %{conn: conn} do
    stub_hetzner(server("unclaimed-box"))

    {:ok, view, _html} = live(conn, ~p"/app/servers")
    link_and_edit(view, "unclaimed-box")

    # A purpose that matches no project's environment stays a label only --
    # same as `qa-story-812` always has (criterion 817) -- and must not be
    # shown as though it linked anything.
    save_environment(view, "a-purpose-nothing-uses")

    html = reload(conn)
    assert html =~ "a-purpose-nothing-uses"
    assert html =~ "not used by any project"
  end

  test "clearing the environment unlinks it", %{conn: conn, scope: scope} do
    stub_hetzner(server("fuellytics"))

    project = CodeMySpec.ProjectsFixtures.project_fixture(scope, name: "Metric Flow")
    project_scope = project_scope(scope, project)
    {:ok, _env} = EnvironmentRepository.put(project_scope, "uat", %{})

    {:ok, view, _html} = live(conn, ~p"/app/servers")
    link_and_edit(view, "fuellytics")
    save_environment(view, "uat")

    assert %{server_id: server_id} = EnvironmentRepository.get(project_scope, "uat")
    refute is_nil(server_id)
    assert reload(conn) =~ "Metric Flow / uat"

    view
    |> element("[data-test='server'][data-name='fuellytics'] [data-test='edit-server']")
    |> render_click()

    save_environment(view, "")

    assert %{server_id: nil} = EnvironmentRepository.get(project_scope, "uat")
    assert reload(conn) =~ "not used by any project"
  end

  test "changing the label to a different name releases what it used to match", %{
    conn: conn,
    scope: scope
  } do
    stub_hetzner(server("fuellytics"))

    project = CodeMySpec.ProjectsFixtures.project_fixture(scope, name: "Metric Flow")
    project_scope = project_scope(scope, project)
    {:ok, _env} = EnvironmentRepository.put(project_scope, "uat", %{})

    {:ok, view, _html} = live(conn, ~p"/app/servers")
    link_and_edit(view, "fuellytics")
    save_environment(view, "uat")
    assert %{server_id: uat_server_id} = EnvironmentRepository.get(project_scope, "uat")
    refute is_nil(uat_server_id)

    view
    |> element("[data-test='server'][data-name='fuellytics'] [data-test='edit-server']")
    |> render_click()

    save_environment(view, "staging")

    assert %{server_id: nil} = EnvironmentRepository.get(project_scope, "uat")
  end
end
