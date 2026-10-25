defmodule CodeMySpecWeb.LocalSetupTest do
  use CodeMySpecTest.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias CodeMySpec.{Devices, Projects}

  defmodule Backend do
    def run(_scope, project, action, _app) do
      send(
        Application.fetch_env!(:code_my_spec, :setup_test_pid),
        {:setup_action, action, project.id}
      )

      {:ok,
       %{
         device_id: Application.fetch_env!(:code_my_spec, :setup_test_device),
         running: false,
         directory: "/example/project",
         result: nil,
         machine_snapshot: nil,
         snapshot: nil
       }}
    end
  end

  setup [:register_log_in_setup_account]

  setup %{scope: scope} do
    project = CodeMySpec.ProjectsFixtures.project_fixture(scope)
    scope = %{scope | active_project_id: project.id, active_project: project}
    {:ok, _} = Projects.Onboarding.save(scope, %{"onboarding" => %{"destination" => "local"}})
    {:ok, device} = Devices.announce(scope, Ecto.UUID.generate(), %{kind: :local})

    overrides = [
      env: :desktop,
      desktop_project_setup: {Backend, :run},
      setup_test_pid: self(),
      setup_test_device: device.id
    ]

    previous =
      for {key, value} <- overrides do
        old = Application.fetch_env(:code_my_spec, key)
        Application.put_env(:code_my_spec, key, value)
        {key, old}
      end

    on_exit(fn ->
      for {key, old} <- previous do
        CodeMySpecTest.EnvRestore.restore_fetched_app_env(key, old)
      end
    end)

    %{scope: scope, project: project, device: device}
  end

  test "device link, page, and Main's tool use the same backend", %{
    conn: conn,
    project: project,
    device: device,
    scope: scope
  } do
    path = "/app/projects/#{project.id}/console/devices/#{device.id}/setup"
    {:ok, index, _} = live(conn, "/app/projects/#{project.id}/console/devices")
    assert has_element?(index, "a[data-test=device-setup][href='#{path}']")
    {:ok, view, _} = live(conn, path)
    view |> element("button[phx-value-action=check]") |> render_click()
    assert_receive {:setup_action, "check", _}

    assert {:ok, _} =
             CodeMySpec.Projects.Tools.SetupLocalProject.script_result(%{"action" => "check"}, %{
               scope: scope
             })

    assert_receive {:setup_action, "check", _}
  end

  test "another device cannot execute setup on the desktop host", %{
    conn: conn,
    project: project,
    scope: scope
  } do
    {:ok, other} = Devices.announce(scope, Ecto.UUID.generate(), %{kind: :local})

    {:ok, view, html} =
      live(conn, "/app/projects/#{project.id}/console/devices/#{other.id}/setup")

    assert html =~ "this desktop"
    refute has_element?(view, "button[phx-value-action=check]")
  end
end
