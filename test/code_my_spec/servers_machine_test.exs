defmodule CodeMySpec.ServersMachineTest do
  use CodeMySpecTest.DataCase, async: true
  import CodeMySpec.UsersFixtures
  alias CodeMySpec.{AccountSecrets, Devices, Environments, Servers}
  alias CodeMySpec.Provisioning.Hetzner

  setup do
    scope = full_scope_fixture()
    AccountSecrets.put_value(scope, "hetzner_api_token", "test-token")

    Req.Test.stub(Hetzner, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "servers" => [%{"id" => 123, "name" => "provider-box", "status" => "running"}]
        })
      )
    end)

    %{scope: scope}
  end

  test "linking exposes machine identity separately from provider inventory ID", %{scope: scope} do
    assert {:ok, server} = Servers.link(scope, "provider-box")
    assert server.id == 123
    device = Servers.get_linked(scope, "provider-box")
    assert server.device_id == device.id
    assert device.provider_name == "provider-box"
    assert {:ok, again} = Servers.link(scope, "provider-box")
    assert again.device_id == device.id
    assert {:ok, [listed]} = Servers.list(scope)
    assert listed.id == 123
    assert listed.device_id == device.id
  end

  test "same-name replacement inventory never acquires the original machine identity", %{
    scope: scope
  } do
    {:ok, original} = Servers.link(scope, "provider-box")

    Req.Test.stub(Hetzner, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "servers" => [
            %{
              "id" => 456,
              "name" => "provider-box",
              "ip" => "203.0.113.55",
              "status" => "running"
            }
          ]
        })
      )
    end)

    assert {:error, :provider_identity_conflict} = Servers.link(scope, "provider-box")
    assert {:ok, [row]} = Servers.list(scope)
    assert row.identity_conflict
    assert row.missing
    assert row.device_id == original.device_id
    assert row.id == nil
    assert row.ip == nil
    assert row.replacement_resource_id == 456
    assert {:ok, same} = Servers.get(scope, "provider-box")
    assert same == row
    assert Devices.get_device(scope, original.device_id).provider_resource_id == "123"
  end

  test "retirement unlinks provider metadata without deleting machine identity", %{scope: scope} do
    {:ok, server} = Servers.link(scope, "provider-box")
    assert :ok = Servers.retire(scope, "provider-box")
    assert Servers.get_linked(scope, "provider-box") == nil
    assert Devices.get_device(scope, server.device_id).id == server.device_id
  end

  test "a linked environment blocks retirement", %{scope: scope} do
    {:ok, server} = Servers.link(scope, "provider-box")
    {:ok, _} = Environments.put(scope, "uat", %{device_id: server.device_id})
    assert {:error, {:in_use, [_]}} = Servers.retire(scope, "provider-box")
    assert Servers.get_linked(scope, "provider-box").id == server.device_id
  end

  test "another account cannot use purpose synchronization to bind a foreign machine", %{
    scope: scope
  } do
    other = full_scope_fixture()
    {:ok, server} = Servers.link(scope, "provider-box")
    device = Servers.get_linked(scope, "provider-box")
    {:ok, device} = Servers.update_server(device, %{purpose: "uat"})
    {:ok, _} = Environments.put(other, "uat", %{})
    assert :ok = Servers.sync_linked_environments(other, device)
    assert Environments.get(other, "uat").device_id == nil
    assert Devices.get_device(scope, server.device_id)
  end
end
