defmodule CodeMySpec.EnvironmentsToolsTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  alias CodeMySpec.{AppInstances, Environments, ToolLibrary}
  alias CodeMySpec.Environments.Tools.{AssignAppInstanceEnvironment, ListEnvironments}

  test "listing is pure and project scoped" do
    scope = full_scope_fixture()
    other = full_scope_fixture()
    {:ok, _} = Environments.put(other, "private", %{})

    assert {:ok, []} = ListEnvironments.script_result(%{}, %{scope: scope})
    assert Environments.list_existing(scope) == []
    assert {:ok, ListEnvironments} = ToolLibrary.fetch("list_environments")
  end

  test "lists only explicit public metadata and JSON-safe values" do
    scope = full_scope_fixture()
    {:ok, environment} = Environments.put(scope, "development", %{management: :harness})

    {:ok, instance} =
      instance(scope, %{environment_id: environment.id, preview_tunnel_secret: "secret-value"})

    assert {:ok, [row]} = ListEnvironments.script_result(%{}, %{scope: scope})
    assert row["id"] == environment.id
    assert row["management"] == "harness"
    assert [runtime] = row["instances"]
    assert runtime["id"] == instance.id

    assert Enum.sort(Map.keys(runtime)) ==
             ~w(commit deployment_image device_id id serving_commit source_root status working_copy_id)

    encoded = Jason.encode!(row)
    refute encoded =~ "secret-value"
    refute encoded =~ "preview_tunnel_secret"
  end

  test "assignment changes the destination without changing runtime state" do
    scope = full_scope_fixture()
    {:ok, environment} = Environments.put(scope, "uat", %{})
    {:ok, instance} = instance(scope, %{status: "serving", serving_commit: "revision"})
    params = %{instance_id: instance.id, environment_id: environment.id}

    assert {:ok, %{"instance_id" => id, "environment_id" => environment_id}} =
             AssignAppInstanceEnvironment.script_result(params, %{scope: scope})

    assert id == instance.id
    assert environment_id == environment.id
    updated = AppInstances.get(scope, instance.id)
    assert updated.environment_id == environment.id
    assert updated.status == "serving"
    assert updated.serving_commit == "revision"
    assert updated.source_root == instance.source_root
  end

  test "assignment rejects another project's instance or environment" do
    scope = full_scope_fixture()
    other = full_scope_fixture()
    {:ok, local_environment} = Environments.put(scope, "uat", %{})
    {:ok, other_environment} = Environments.put(other, "uat", %{})
    {:ok, local_instance} = instance(scope)
    {:ok, other_instance} = instance(other)

    for params <- [
          %{instance_id: local_instance.id, environment_id: other_environment.id},
          %{instance_id: other_instance.id, environment_id: local_environment.id}
        ] do
      assert {:error, :not_found} =
               AssignAppInstanceEnvironment.script_result(params, %{scope: scope})
    end

    assert AppInstances.get(scope, local_instance.id).environment_id == nil
    assert AppInstances.get(other, other_instance.id).environment_id == nil
  end

  test "ensure environment supports harness management and preserves the provider default" do
    scope = full_scope_fixture()
    context = %{scope: scope}

    assert {:ok, _} =
             ToolLibrary.run(
               "ensure_environment",
               %{name: "development", management: "harness"},
               context
             )

    assert Environments.get(scope, "development").management == :harness
    assert {:ok, _} = ToolLibrary.run("ensure_environment", %{name: "uat"}, context)
    assert Environments.get(scope, "uat").management == :provisioned

    assert {:error, _} =
             ToolLibrary.run(
               "ensure_environment",
               %{name: "development", management: "provisioned"},
               context
             )

    assert Environments.get(scope, "development").management == :harness
  end

  defp instance(scope, attrs \\ %{}) do
    AppInstances.create(
      scope,
      Map.merge(%{port_mode: :configured, database_mode: :configured, default: false}, attrs)
    )
  end
end
