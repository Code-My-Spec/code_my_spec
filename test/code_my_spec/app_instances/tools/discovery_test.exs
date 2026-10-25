defmodule CodeMySpec.AppInstances.Tools.DiscoveryTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  alias CodeMySpec.{AppInstances, Environments}
  alias CodeMySpec.AppInstances.Tools.{GetAppInstance, ListAppInstances}

  test "discovers deployments without a checkout, serializes dates, and excludes credentials" do
    scope = full_scope_fixture()
    {:ok, environment} = Environments.put(scope, "prod", %{})
    now = DateTime.utc_now()

    {:ok, instance} =
      AppInstances.record_deployment(scope, environment.id, %{
        confirmed_at: now,
        image: "example/app:release",
        commit: "abc123"
      })

    {:ok, instance} =
      AppInstances.update(scope, instance, %{
        preview_tunnel_secret: "secret-must-not-escape",
        preview_checked_at: now
      })

    context = %{scope: %{scope | active_working_copy_id: nil}}
    assert {:ok, [row]} = ListAppInstances.script_result(%{}, context)
    assert row["id"] == instance.id
    assert row["working_copy_id"] == nil
    assert row["deployment_image"] == "example/app:release"
    assert row["preview_checked_at"] == DateTime.to_iso8601(now)
    refute Map.has_key?(row, "preview_tunnel_secret")
    refute Map.has_key?(row, "promotion_sync")
    assert {:ok, ^row} = GetAppInstance.script_result(%{instance_id: instance.id}, context)
    assert {:ok, json} = GetAppInstance.call(%{instance_id: instance.id}, context)
    assert Jason.decode!(json) == row
    refute json =~ "secret-must-not-escape"
  end

  test "discovery is project scoped and invalid IDs return errors" do
    scope = full_scope_fixture()
    other = full_scope_fixture()

    {:ok, instance} =
      AppInstances.create(scope, %{port_mode: :configured, database_mode: :configured})

    context = %{scope: other}
    assert {:ok, []} = ListAppInstances.script_result(%{}, context)

    assert {:error, :not_found} =
             GetAppInstance.script_result(%{instance_id: instance.id}, context)

    assert {:error, :invalid_instance_id} =
             GetAppInstance.script_result(%{instance_id: "bad"}, context)

    assert {:error, :missing_active_project} = ListAppInstances.script_result(%{}, %{})
  end
end
