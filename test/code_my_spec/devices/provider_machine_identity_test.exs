defmodule CodeMySpec.Devices.ProviderMachineIdentityTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.AccountsFixtures
  import CodeMySpec.ProjectsFixtures
  alias CodeMySpec.{Devices, Repo, WorkingCopies}
  alias CodeMySpec.Devices.Device

  setup do
    %{scope: owner_scope()}
  end

  defp owner_scope do
    owner = user_fixture()
    account = account_with_owner_fixture(owner)
    project = project_fixture(user_scope_fixture(owner, account))
    user_scope_fixture(owner, account, project)
  end

  test "enrollment and subsequent announcements retain one provider machine", %{scope: scope} do
    assert {:ok, linked} = Devices.link_provider_machine(scope, %{name: "production", id: 123})
    assert linked.provider_resource_id == "123"
    assert linked.last_seen_at == nil
    assert linked.token_hash == nil
    assert {:ok, same} = Devices.link_provider_machine(scope, %{name: "production"})
    assert same.id == linked.id
    assert same.provider_resource_id == "123"
    assert {:ok, enrolled, token} = Devices.enroll_existing_device(scope, linked.id)
    assert enrolled.id == linked.id
    assert Devices.sign_in_with_token(token).id == linked.id
    assert {:ok, announced} = Devices.announce_box(enrolled, %{hostname: "actual-host"})
    assert announced.id == linked.id
    assert announced.provider == :hetzner

    assert {:ok, recognized} =
             Devices.announce(scope, linked.id, %{hostname: "actual-host", kind: :cloud})

    assert recognized.id == linked.id
    assert Enum.count(Devices.list_provider_machines(scope)) == 1
    assert {:error, :already_enrolled} = Devices.enroll_existing_device(scope, linked.id)
  end

  test "unlink preserves credentials and checkouts; purpose may be cleared", %{scope: scope} do
    {:ok, device} = Devices.link_provider_machine(scope, %{name: "production"})
    {:ok, device, token} = Devices.enroll_existing_device(scope, device.id)
    {:ok, copy} = WorkingCopies.issue(scope, nil, device: device, root: "/srv/app")
    assert {:ok, device} = Devices.update_machine_purpose(device, %{purpose: " production "})
    assert device.purpose == "production"
    assert {:ok, device} = Devices.update_machine_purpose(device, %{purpose: nil})
    assert device.purpose == nil
    assert {:ok, unlinked} = Devices.unlink_provider_machine(scope, device.id)
    assert unlinked.provider == nil
    assert Device.display_name(unlinked) == "production"
    assert Repo.get!(Device, device.id).token_hash == device.token_hash
    assert Devices.sign_in_with_token(token).id == device.id
    assert Repo.get!(WorkingCopies.WorkingCopy, copy.id).device_id == device.id
  end

  test "provider identity can be enriched without changing its device ID", %{scope: scope} do
    {:ok, first} = Devices.link_provider_machine(scope, %{name: "production"})
    assert {:ok, enriched} = Devices.link_provider_machine(scope, %{name: "production", id: 456})
    assert enriched.id == first.id
    assert enriched.provider_resource_id == "456"
  end

  test "a replacement provider machine cannot inherit an existing machine identity", %{
    scope: scope
  } do
    {:ok, original} = Devices.link_provider_machine(scope, %{name: "production", id: 123})
    {:ok, original, token} = Devices.enroll_existing_device(scope, original.id)

    assert {:error, :provider_identity_conflict} =
             Devices.link_provider_machine(scope, %{name: "production", id: 456})

    assert Devices.get_provider_machine(scope, "production").provider_resource_id == "123"
    assert Devices.sign_in_with_token(token).id == original.id
  end

  test "the same provider resource under a new name cannot become a second machine", %{
    scope: scope
  } do
    {:ok, original} = Devices.link_provider_machine(scope, %{name: "production", id: 123})

    assert {:error, %Ecto.Changeset{}} =
             Devices.link_provider_machine(scope, %{name: "renamed", id: 123})

    assert Devices.get_provider_machine(scope, "renamed") == nil
    assert Enum.map(Devices.list_provider_machines(scope), & &1.id) == [original.id]
  end

  test "environment attachment prevents direct unlink or device deletion", %{scope: scope} do
    {:ok, device} = Devices.link_provider_machine(scope, %{name: "production"})

    {:ok, _environment} =
      CodeMySpec.Environments.put_deployment(scope, "prod", %{
        device_id: device.id
      })

    assert {:error, :in_use} = Devices.unlink_provider_machine(scope, device.id)
    assert {:error, :in_use} = Devices.destroy(scope, device)
    assert Devices.get_provider_machine(scope, "production").id == device.id
  end

  test "another account cannot enroll or unlink the device", %{scope: scope} do
    other = owner_scope()
    {:ok, device} = Devices.link_provider_machine(scope, %{name: "production"})
    assert {:error, :not_found} = Devices.enroll_existing_device(other, device.id)
    assert {:error, :not_found} = Devices.unlink_provider_machine(other, device.id)
    assert Devices.get_provider_machine(other, "production") == nil
  end
end
