defmodule CodeMySpec.DevicesToolsTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.{Devices, Environments, Repo, WorkingCopies}
  alias CodeMySpec.Accounts.MembersRepository
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Devices.Tools.{GetDevice, ListDevices, RetireDevice}

  test "lists account devices but only this project's copies and connections" do
    scope = full_scope_fixture()
    other = full_scope_fixture()
    device = device_fixture(scope)
    hidden = device_fixture(other)
    {:ok, local_copy} = WorkingCopies.issue(scope, nil, device: device)
    {:ok, other_copy} = WorkingCopies.issue(other, nil, device: device)
    :ok = HarnessRegistry.register_executor(other_copy.id)

    assert {:ok, rows} = ListDevices.script_result(%{}, %{scope: scope})
    assert length(rows) == 2
    row = Enum.find(rows, &(&1["id"] == device.id))
    refute Enum.any?(rows, &(&1["id"] == hidden.id))
    assert row["id"] == device.id
    assert row["working_copy_ids"] == [local_copy.id]
    assert row["connected_working_copy_ids"] == []
    refute row["project_harness_connected"]

    assert {:error, :not_found} =
             GetDevice.script_result(%{device_id: hidden.id}, %{scope: scope})

    :ok = HarnessRegistry.register_executor(local_copy.id)
    assert {:ok, row} = GetDevice.script_result(%{device_id: device.id}, %{scope: scope})
    assert row["project_harness_connected"]
    assert row["connected_working_copy_ids"] == [local_copy.id]
    assert row["enrollment_status"] == "not_enrolled"
  end

  test "deployment machines are discoverable without copies or harness enrollment" do
    scope = full_scope_fixture()
    {:ok, device} = Devices.link_provider_machine(scope, %{name: "production", id: 123})
    assert {:ok, rows} = ListDevices.script_result(%{}, %{scope: scope})
    assert length(rows) == 2
    row = Enum.find(rows, &(&1["id"] == device.id))
    assert row["id"] == device.id
    assert row["provider"] == "hetzner"
    assert row["provider_resource_id"] == "123"
    assert row["display_name"] == "production"
    assert row["working_copy_ids"] == []
    assert row["last_seen_at"] == nil
    refute row["project_harness_connected"]
  end

  test "safe DTO contains ISO timestamps and no credentials; recent observation is not presence" do
    scope = full_scope_fixture()
    device = device_fixture(scope)

    Repo.update!(
      Ecto.Changeset.change(device,
        token_hash: "private-hash",
        preview_tunnel_secret: "secret-tunnel",
        fire_token: "secret-fire"
      )
    )

    assert {:ok, row} = GetDevice.script_result(%{device_id: device.id}, %{scope: scope})
    assert row["last_seen_at"] == DateTime.to_iso8601(device.last_seen_at)
    assert row["enrollment_status"] == "enrolled"
    refute row["project_harness_connected"]

    assert Enum.sort(Map.keys(row)) ==
             ~w(connected_working_copy_ids display_name enrollment_status hostname id kind last_seen_at project_harness_connected provider provider_name provider_resource_id purpose working_copy_ids)

    assert {:ok, json} = GetDevice.call(%{device_id: device.id}, %{scope: scope})
    assert Jason.decode!(json) == row
    refute json =~ "private-hash"
    refute json =~ "secret-"

    Repo.update!(Ecto.Changeset.change(device, token_revoked_at: DateTime.utc_now()))
    assert {:ok, row} = GetDevice.script_result(%{device_id: device.id}, %{scope: scope})
    assert row["enrollment_status"] == "revoked"
  end

  test "account owner retires an unbound device by exact display name" do
    scope = owner_scope_fixture()
    device = device_fixture(scope)
    {:ok, copy} = WorkingCopies.issue(scope, nil, label: "orphan", device: device)

    assert {:ok, result} =
             RetireDevice.script_result(%{device_name: device.hostname}, %{scope: scope})

    assert result == %{"device_id" => device.id, "display_name" => device.hostname}
    assert Devices.get_device(scope, device.id) == nil
    assert {:error, :not_found} = WorkingCopies.fetch(copy.id)
  end

  test "main agent may retire an unbound device while an ordinary member may not" do
    scope = full_scope_fixture()
    device = device_fixture(scope)

    assert {:error, :forbidden} =
             RetireDevice.script_result(%{device_name: device.hostname}, %{scope: scope})

    {:ok, _} = CodeMySpec.Staffing.designate_main(scope, scope.active_working_copy_id)

    {:ok, main} =
      AgentsRepository.create_agent(scope, %{
        engine: :alloy,
        provider: "zai",
        working_copy: "/tmp/a-main-copy",
        role: :main,
        working_copy_id: scope.active_working_copy_id
      })

    assert {:ok, %{"device_id" => device_id}} =
             RetireDevice.script_result(
               %{device_name: device.hostname},
               %{scope: scope, agent_id: main.id}
             )

    assert device_id == device.id
    assert Devices.get_device(scope, device.id) == nil
  end

  test "retirement refuses an environment-bound device" do
    scope = owner_scope_fixture()
    device = device_fixture(scope)

    {:ok, environment} =
      Environments.put(scope, "retirement-test", %{management: :harness, device_id: device.id})

    assert environment.device_id == device.id

    assert {:error, :in_use} =
             RetireDevice.script_result(%{device_name: device.hostname}, %{scope: scope})

    assert Devices.get_device(scope, device.id)
  end

  test "retirement requires account ownership or the main agent and rejects unknown names" do
    scope = owner_scope_fixture()
    other = full_scope_fixture()
    device = device_fixture(scope)
    hidden = device_fixture(other)
    unauthenticated = %{scope | user: nil}

    assert {:error, :forbidden} =
             RetireDevice.script_result(%{device_name: device.hostname}, %{scope: unauthenticated})

    assert {:error, :not_found} =
             RetireDevice.script_result(%{device_name: hidden.hostname}, %{scope: scope})

    assert Devices.get_device(scope, device.id)
    assert Devices.get_device(other, hidden.id)
  end

  test "rejects missing scope and invalid UUID without raising" do
    scope = full_scope_fixture()
    assert {:error, :missing_active_project} = ListDevices.script_result(%{}, %{})

    assert {:error, :missing_active_project} =
             GetDevice.script_result(%{device_id: "invalid"}, %{})

    for id <- ["invalid", "123", nil, %{}] do
      assert {:error, :invalid_device_id} =
               GetDevice.script_result(%{device_id: id}, %{scope: scope})
    end
  end

  defp owner_scope_fixture do
    scope = full_scope_fixture()

    {:ok, _member} =
      MembersRepository.update_user_role(scope.user.id, scope.active_account_id, :owner)

    scope
  end
end
