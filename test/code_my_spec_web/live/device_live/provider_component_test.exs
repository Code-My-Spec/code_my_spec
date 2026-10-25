defmodule CodeMySpecWeb.DeviceLive.ProviderComponentTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AccountSecrets
  alias CodeMySpec.Devices
  alias CodeMySpec.Provisioning.Hetzner
  alias CodeMySpecWeb.DeviceLive.ProviderComponent

  test "purpose saves and harness presence updates preserve provider cache and staged choices" do
    scope = full_scope_fixture()
    AccountSecrets.put_value(scope, "hetzner_api_token", "test-token")

    Req.Test.stub(Hetzner, fn _conn ->
      flunk("Local UI updates must not refetch provider inventory or available sizes")
    end)

    {:ok, device} = Devices.link_provider_machine(scope, %{name: "provider-box", id: 123})
    {:ok, device} = Devices.update_machine_purpose(device, %{purpose: "uat"})
    pending = %{size: "cpx11", location: "ash", hourly: 0.01}
    options = [%{location: "ash", types: [%{name: "cpx11", hourly: 0.01}]}]

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        current_scope: scope,
        servers: [%{device_id: device.id, environment: "prod"}],
        edit_name: nil,
        refresh: 0,
        location: "ash",
        options: options,
        pending: pending
      }
    }

    assert {:ok, socket} = ProviderComponent.update(%{saved_server: device}, socket)
    assert hd(socket.assigns.servers).environment == "uat"

    assert {:ok, socket} =
             ProviderComponent.update(
               %{current_scope: scope, refresh: 0, connected_device_ids: [device.id]},
               socket
             )

    assert socket.assigns.options == options
    assert socket.assigns.location == "ash"
    assert socket.assigns.pending == pending
    assert socket.assigns.connected_device_ids == [device.id]
  end
end
