defmodule CodeMySpecWeb.DeviceLive.ProviderMachineTest do
  use CodeMySpecTest.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias CodeMySpec.Devices

  setup :register_log_in_setup_account
  setup :setup_active_project

  test "provider-only machine does not claim the server is down", %{
    conn: conn,
    scope: scope,
    project: project
  } do
    {:ok, device} = Devices.link_provider_machine(scope, %{name: "production-box", id: 123})
    {:ok, view, _} = live(conn, "/app/projects/#{project.id}/console/dev-boxes")
    row = "[data-test=device][data-device-id='#{device.id}']"
    assert has_element?(view, "#{row} [data-test=provider-machine]", "Hetzner")
    assert has_element?(view, "#{row} [data-test=device-presence]", "Harness not connected")
    refute has_element?(view, "#{row} [data-test=dev-box-up]")
    assert has_element?(view, "#{row} [data-test=enroll-machine]")
  end

  test "enrollment connects the existing machine identity", %{
    conn: conn,
    scope: scope,
    project: project
  } do
    {:ok, device} = Devices.link_provider_machine(scope, %{name: "existing-box", id: 456})
    before_ids = Enum.map(Devices.list_devices(scope), & &1.id)
    {:ok, view, _} = live(conn, "/app/projects/#{project.id}/console/dev-boxes")

    view
    |> element("[data-test=device][data-device-id='#{device.id}'] [data-test=enroll-machine]")
    |> render_click()

    token =
      view
      |> element("[data-test=new-dev-box-token]")
      |> render()
      |> Floki.parse_fragment!()
      |> Floki.attribute("code", "data-token")
      |> List.first()

    assert Devices.sign_in_with_token(token).id == device.id
    assert Enum.map(Devices.list_devices(scope), & &1.id) == before_ids

    refute has_element?(
             view,
             "[data-test=device][data-device-id='#{device.id}'] [data-test=enroll-machine]"
           )
  end
end
