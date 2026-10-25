defmodule CodeMySpec.AppInstancesDeploymentTest do
  use CodeMySpecTest.DataCase, async: true
  import CodeMySpec.UsersFixtures
  alias CodeMySpec.{AppInstances, Devices, Environments}

  test "deployment belongs to the destination machine, never the deploying machine" do
    scope = full_scope_fixture()
    {:ok, destination} = Devices.link_provider_machine(scope, %{name: "production", id: 123})
    {:ok, deployer} = Devices.announce(scope, nil, %{kind: :local, hostname: "developer"})
    {:ok, environment} = Environments.put(scope, "prod", %{device_id: destination.id})

    assert {:ok, instance} =
             AppInstances.record_deployment(scope, environment.id, %{
               confirmed_at: DateTime.utc_now(),
               image: "app:release",
               device_id: deployer.id
             })

    assert instance.device_id == destination.id
    assert instance.working_copy_id == nil
  end

  test "repeated deployments and destination moves preserve one provider runtime identity" do
    scope = full_scope_fixture()
    first_device = CodeMySpec.DevicesFixtures.device_fixture(scope)
    next_device = CodeMySpec.DevicesFixtures.device_fixture(scope)
    {:ok, environment} = Environments.put(scope, "uat", %{device_id: first_device.id})
    receipt = %{confirmed_at: DateTime.utc_now(), image: "registry/app:first"}
    {:ok, first} = AppInstances.record_deployment(scope, environment.id, receipt)
    {:ok, repeated} = AppInstances.record_deployment(scope, environment.id, receipt)
    assert repeated.id == first.id
    assert repeated.device_id == first_device.id

    assert {:error, :scope_mismatch} =
             AppInstances.update(scope, repeated, %{device_id: next_device.id})

    {:ok, _} = Environments.put(scope, "uat", %{device_id: next_device.id})

    {:ok, moved} =
      AppInstances.record_deployment(scope, environment.id, %{
        receipt
        | image: "registry/app:next"
      })

    assert moved.id == first.id
    assert moved.device_id == next_device.id
    assert [only] = AppInstances.list_for_environment(scope, environment.id)
    assert only.id == first.id
  end

  test "confirmed deployments retain one rootless runtime identity and replace its receipt" do
    scope = full_scope_fixture()
    {:ok, environment} = Environments.put(scope, "uat", %{})

    receipt = %{
      confirmed_at: DateTime.utc_now(),
      image: "registry/app:release",
      url: "https://uat.example.com",
      commit: String.duplicate("a", 40)
    }

    assert {:ok, first} = AppInstances.record_deployment(scope, environment.id, receipt)
    assert first.persistent
    refute first.default
    assert first.working_copy_id == nil
    assert first.device_id == nil
    assert first.source_root == nil
    assert first.serving_commit == receipt.commit
    assert first.deployment_image == receipt.image
    assert first.status == "serving"
    assert first.checked_at == receipt.confirmed_at

    unknown = %{confirmed_at: DateTime.utc_now(), image: "registry/app:latest", url: receipt.url}
    assert {:ok, next} = AppInstances.record_deployment(scope, environment.id, unknown)
    assert next.id == first.id
    assert next.deployment_image == unknown.image
    assert next.serving_commit == nil
    assert next.commit == nil
    assert [only] = AppInstances.list_for_environment(scope, environment.id)
    assert only.id == first.id
  end

  test "a failed or unconfirmed deployment cannot replace the serving receipt" do
    scope = full_scope_fixture()
    {:ok, environment} = Environments.put(scope, "prod", %{})
    receipt = %{confirmed_at: DateTime.utc_now(), image: "registry/app:stable"}
    {:ok, instance} = AppInstances.record_deployment(scope, environment.id, receipt)

    assert {:error, :unconfirmed_deployment} =
             AppInstances.record_deployment(scope, environment.id, %{
               confirmed_at: nil,
               image: "registry/app:failed"
             })

    assert AppInstances.get(scope, instance.id).deployment_image == receipt.image
    assert AppInstances.get(scope, instance.id).checked_at == receipt.confirmed_at
  end

  test "deployment recording rejects local environments and another project's destinations" do
    scope = full_scope_fixture()
    other = full_scope_fixture()
    {:ok, local} = Environments.put(scope, "development", %{management: :harness})
    {:ok, foreign} = Environments.put(other, "uat", %{})
    receipt = %{confirmed_at: DateTime.utc_now(), image: "registry/app:latest"}

    assert {:error, :not_provisioned_environment} =
             AppInstances.record_deployment(scope, local.id, receipt)

    assert {:error, :environment_not_found} =
             AppInstances.record_deployment(scope, foreign.id, receipt)

    assert AppInstances.list_for_environment(scope, local.id) == []
    assert AppInstances.list_for_environment(other, foreign.id) == []
  end

  test "image tags and digests are not treated as source commits" do
    scope = full_scope_fixture()
    {:ok, environment} = Environments.put(scope, "uat", %{})

    for image <- ["registry:5000/app:latest", "registry/app@sha256:#{String.duplicate("b", 64)}"] do
      assert {:ok, instance} =
               AppInstances.record_deployment(scope, environment.id, %{
                 confirmed_at: DateTime.utc_now(),
                 image: image
               })

      assert instance.deployment_image == image
      assert instance.commit == nil
      assert instance.serving_commit == nil
    end
  end
end
