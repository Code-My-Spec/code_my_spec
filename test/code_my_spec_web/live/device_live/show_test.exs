defmodule CodeMySpecWeb.DeviceLive.ShowTest do
  use CodeMySpecTest.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.AccountSecrets
  alias CodeMySpec.Devices
  alias CodeMySpec.Provisioning.Hetzner

  setup [:register_log_in_setup_account, :setup_active_project]

  defp provider(scope) do
    AccountSecrets.put_value(scope, "hetzner_api_token", "test-token")

    Req.Test.stub(Hetzner, &provider_response/1)
  end

  defp provider_response(%{request_path: "/v1/servers"} = conn) do
    json(conn, %{
      "servers" => [
        %{
          "id" => 123,
          "name" => "shared-box",
          "status" => "running",
          "public_net" => %{"ipv4" => %{"ip" => "10.0.0.1"}},
          "server_type" => %{"name" => "cpx11"}
        }
      ]
    })
  end

  defp provider_response(conn), do: json(conn, %{})

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end

  test "local machine detail offers its harness without making a provider request", %{
    conn: conn,
    scope: scope
  } do
    device = device_fixture(scope, %{hostname: "my-laptop"})
    {:ok, view, _} = live(conn, "/app/devices/#{device.id}")
    assert has_element?(view, "[data-test=device-detail]", "my-laptop")
    assert has_element?(view, "[data-test=device][data-device-id='#{device.id}']")
    refute has_element?(view, "[data-test=server-detail]")
  end

  test "provider detail combines infrastructure and harness for the same machine", %{
    conn: conn,
    scope: scope
  } do
    provider(scope)
    {:ok, device} = Devices.link_provider_machine(scope, %{name: "shared-box", id: 123})
    {:ok, view, _} = live(conn, "/app/devices/#{device.id}")
    assert has_element?(view, "[data-test=server-detail][data-name=shared-box]")
    assert has_element?(view, "[data-test=device][data-device-id='#{device.id}']")
    assert has_element?(view, "[data-test=retire-server]")
    render_settled(view)
    assert has_element?(view, "[data-test=containers-error]")
    refute has_element?(view, "[data-test=no-containers]")
  end

  test "a replacement provider resource remains visibly distinct on device detail", %{
    conn: conn,
    scope: scope
  } do
    provider(scope)
    {:ok, device} = Devices.link_provider_machine(scope, %{name: "shared-box", id: 999})
    {:ok, view, _} = live(conn, "/app/devices/#{device.id}")
    assert has_element?(view, "[data-test=provider-identity-conflict]", "Provider replaced")
    assert has_element?(view, "[data-test=provider-missing]")
    refute render(view) =~ "10.0.0.1"
  end

  test "provider discovery does not pretend a harness machine is already linked", %{
    conn: conn,
    scope: scope
  } do
    provider(scope)
    {:ok, view, _} = live(conn, "/app/devices/provider/shared-box")
    assert has_element?(view, "[data-test=server-detail]")
    refute has_element?(view, "[data-test=device]")
    refute has_element?(view, "[data-test=retire-server]")
  end

  test "retiring provider management retains the harness identity", %{conn: conn, scope: scope} do
    provider(scope)
    {:ok, device} = Devices.link_provider_machine(scope, %{name: "shared-box", id: 123})
    {:ok, view, _} = live(conn, "/app/devices/#{device.id}")
    view |> element("[data-test=retire-server]") |> render_click()
    assert_redirect(view, "/app/devices")
    assert Devices.get_device(scope, device.id)
    assert is_nil(Devices.get_provider_machine(scope, "shared-box"))
  end

  test "project detail stays inside the project navigation", %{
    conn: conn,
    scope: scope,
    project: project
  } do
    device = device_fixture(scope)
    {:ok, view, _} = live(conn, "/app/projects/#{project.id}/console/devices/#{device.id}")
    assert has_element?(view, "a[href='/app/projects/#{project.id}/console/devices']", "Devices")
  end

  test "harness rename refreshes the detail heading", %{conn: conn, scope: scope} do
    device = device_fixture(scope, %{hostname: "old-host"})
    {:ok, view, _} = live(conn, "/app/devices/#{device.id}")
    view |> form("[data-test=rename-device]", %{label: "Build laptop"}) |> render_submit()
    assert has_element?(view, "[data-test=device-detail] h1", "Build laptop")
  end

  test "harness deletion leaves the detail page", %{conn: conn, scope: scope} do
    device = device_fixture(scope)
    {:ok, view, _} = live(conn, "/app/devices/#{device.id}")
    view |> element("[data-test=destroy-device]") |> render_click()
    assert_redirect(view, "/app/devices")
    assert is_nil(Devices.get_device(scope, device.id))
  end

  test "harness notifications refresh and unrelated messages leave detail available", %{
    conn: conn,
    scope: scope
  } do
    device = device_fixture(scope)
    {:ok, view, _} = live(conn, "/app/devices/#{device.id}")

    for event <- [:dev_box_connected, :dev_box_revoked, :device_runtime_changed, :unrelated] do
      send(view.pid, {event, device.id})
      assert has_element?(view, "[data-test=device-detail]")
    end
  end

  test "invalid and unknown machine IDs redirect cleanly", %{conn: conn} do
    for id <- ["invalid", Ecto.UUID.generate()] do
      assert {:error, {:live_redirect, %{to: "/app/devices"}}} = live(conn, "/app/devices/#{id}")
    end
  end
end
