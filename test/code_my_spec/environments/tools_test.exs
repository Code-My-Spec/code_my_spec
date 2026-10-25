defmodule CodeMySpec.Environments.ToolsTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.{AppInstances, Environments, ToolLibrary}
  alias CodeMySpec.Environments.Tools.{AssignEnvironmentDevice, EnsureEnvironment}

  setup do
    scope = full_scope_fixture()
    %{scope: scope, context: %{scope: scope}}
  end

  test "environment creation belongs to Environments and retains its public contract", %{
    scope: scope,
    context: context
  } do
    assert EnsureEnvironment in Environments.Tools.all()
    refute CodeMySpec.Provisioning.Tools.EnsureEnvironment in CodeMySpec.Provisioning.Tools.all()

    assert {:ok, "dev environment ready."} =
             ToolLibrary.run("ensure_environment", %{name: "dev", management: "harness"}, context)

    assert Environments.get(scope, "dev").management == :harness

    assert {:ok, _} =
             CodeMySpec.Provisioning.Tools.EnsureEnvironment.call(%{name: "prod"}, context)

    assert Environments.get(scope, "prod").management == :provisioned

    assert {:error, _} =
             EnsureEnvironment.call(%{name: "dev", management: "provisioned"}, context)
  end

  test "device binding works for both management modes without moving app instances", %{
    scope: scope,
    context: context
  } do
    old_device = device_fixture(scope)
    new_device = device_fixture(scope)

    for management <- [:harness, :provisioned] do
      {:ok, environment} =
        Environments.put(scope, to_string(management), %{management: management})

      {:ok, instance} =
        AppInstances.create(scope, %{
          environment_id: environment.id,
          device_id: old_device.id,
          port_mode: :configured,
          database_mode: :configured
        })

      assert {:ok, json} =
               ToolLibrary.run(
                 "assign_environment_device",
                 %{environment_id: environment.id, device_id: new_device.id},
                 context
               )

      assert Jason.decode!(json) == %{
               "environment_id" => environment.id,
               "device_id" => new_device.id
             }

      assert Environments.get_by_id(scope, environment.id).device_id == new_device.id
      assert AppInstances.get(scope, instance.id).device_id == old_device.id
    end
  end

  test "rejects another project's environment and another account's device", %{
    scope: scope,
    context: context
  } do
    other_scope = full_scope_fixture()
    own_device = device_fixture(scope)
    other_device = device_fixture(other_scope)
    {:ok, own_env} = Environments.put(scope, "dev", %{management: :harness})
    {:ok, other_env} = Environments.put(other_scope, "dev", %{management: :harness})

    assert {:error, :not_found} =
             AssignEnvironmentDevice.script_result(
               %{environment_id: other_env.id, device_id: own_device.id},
               context
             )

    assert {:error, :not_found} =
             AssignEnvironmentDevice.script_result(
               %{environment_id: own_env.id, device_id: other_device.id},
               context
             )

    assert Environments.get_by_id(scope, own_env.id).device_id == nil
    assert Environments.get_by_id(other_scope, other_env.id).device_id == nil
  end

  test "refuses absent scope and invalid identifiers", %{scope: scope, context: context} do
    device = device_fixture(scope)

    assert {:error, :missing_active_project} =
             AssignEnvironmentDevice.script_result(
               %{environment_id: Ecto.UUID.generate(), device_id: device.id},
               %{}
             )

    assert {:error, :not_found} =
             AssignEnvironmentDevice.script_result(
               %{environment_id: "invalid", device_id: device.id},
               context
             )

    assert {:error, :invalid_device_id} =
             AssignEnvironmentDevice.script_result(
               %{environment_id: Ecto.UUID.generate(), device_id: nil},
               context
             )

    assert {:error, :invalid_device_id} =
             AssignEnvironmentDevice.script_result(
               %{environment_id: Ecto.UUID.generate(), device_id: "invalid"},
               context
             )
  end
end
