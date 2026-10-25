defmodule CodeMySpec.DevicesToolsTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.{Devices, Repo, WorkingCopies}
  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Devices.Tools.{GetDevice, ListDevices}

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
end
