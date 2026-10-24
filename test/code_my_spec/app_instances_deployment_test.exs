defmodule CodeMySpec.AppInstancesDeploymentTest do
  use CodeMySpecTest.DataCase, async: true
  import CodeMySpec.UsersFixtures
  alias CodeMySpec.{AppInstances, Environments}

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
