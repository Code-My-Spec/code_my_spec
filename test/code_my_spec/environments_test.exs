defmodule CodeMySpec.EnvironmentsTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  alias CodeMySpec.Environments
  alias CodeMySpec.Users.Scope

  setup do
    %{scope: full_scope_fixture()}
  end

  test "ordinary reads never create destinations", %{scope: scope} do
    assert Environments.list(scope) == []
    assert Environments.list_existing(scope) == []
    assert Environments.list_existing_deployment(scope) == []
    assert Environments.get(scope, "prod") == nil
    assert Environments.list(scope) == []
  end

  test "development is idempotent and does not seed deployments", %{scope: scope} do
    assert {:ok, first} = Environments.ensure_development(scope)

    assert {:ok, again} =
             Environments.ensure_development(%Scope{active_project_id: scope.active_project_id})

    assert first.id == again.id
    assert first.management == :harness
    assert first.host == nil
    assert first.device_id == nil
    assert Environments.list(scope) == [first]
    assert Environments.list_existing_deployment(scope) == []
  end

  test "custom harness destinations are not mistaken for development", %{scope: scope} do
    {:ok, staging} = Environments.put(scope, "staging", %{management: :harness})
    {:ok, development} = Environments.ensure_development(scope)
    assert development.name == "dev"
    refute development.id == staging.id
    assert {:ok, ^development} = Environments.ensure_development(scope)
  end

  test "malformed environment ids return no result", %{scope: scope} do
    assert Environments.get_by_id(scope, "not-a-uuid") == nil
    assert Environments.get_by_id(scope, nil) == nil
    assert Environments.get_by_id(scope, 42) == nil
  end

  test "development does not repurpose an existing provisioned destination", %{scope: scope} do
    assert {:ok, original} = Environments.put(scope, "dev", %{host: "dev.example.com"})
    assert {:ok, development} = Environments.ensure_development(scope)
    assert development.name == "dev-local"
    assert development.management == :harness
    assert {:ok, ^development} = Environments.ensure_development(scope)
    assert Environments.get(scope, "dev") == original
  end

  test "deployment initialization still seeds with a local development destination present", %{
    scope: scope
  } do
    {:ok, development} = Environments.ensure_development(scope)
    deployments = Environments.list_deployment(scope)
    assert Enum.map(deployments, & &1.name) == ["prod", "uat"]
    assert Enum.all?(deployments, &(&1.management == :provisioned))
    assert Environments.list_deployment(scope) == deployments
    Environments.assign_deployment_hosts(scope, "example.com")
    assert Environments.get(scope, "prod").host == "example.com"
    assert Environments.get(scope, "uat").host == "uat.example.com"
    assert Environments.get(scope, "dev") == development
    assert Environments.get_deployment(scope, "dev") == nil
  end

  test "custom deployments suppress legacy seeding", %{scope: scope} do
    {:ok, stage} = Environments.put(scope, "stage", %{})
    assert Environments.list_deployment(scope) == [stage]
  end

  test "management is immutable and provider writes cannot touch harness destinations", %{
    scope: scope
  } do
    {:ok, development} = Environments.ensure_development(scope)
    assert {:error, changeset} = Environments.put(scope, "dev", %{management: :provisioned})
    assert "cannot be changed after creation" in errors_on(changeset).management

    assert {:error, :not_provisioned_environment} =
             Environments.put_deployment(scope, "dev", %{host: "bad.example.com"})

    assert {:error, :not_provisioned_environment} =
             Environments.put_deployment(scope, "other", %{"management" => "harness"})

    assert Environments.get(scope, "dev") == development
  end

  test "scoped access and writes cannot leak into another project", %{scope: scope} do
    other = full_scope_fixture()
    {:ok, environment} = Environments.put(scope, "qa", %{"project_id" => other.active_project_id})
    assert environment.project_id == scope.active_project_id
    assert Environments.get_by_id(other, environment.id) == nil
    mismatched = %{scope | active_project: other.active_project}
    assert Environments.get_by_id(mismatched, environment.id) == environment

    assert Environments.get(other, "qa") == nil
    assert Environments.list(other) == []
    assert :ok = Environments.delete(other, "qa")
    assert Environments.get_by_id(scope, environment.id) == environment

    assert {:ok, updated} =
             Environments.put(%Scope{active_project_id: scope.active_project_id}, "qa", %{
               project_id: other.active_project_id,
               host: "qa.example.com"
             })

    assert updated.project_id == scope.active_project_id
  end

  test "a destination with app instances cannot be deleted", %{scope: scope} do
    {:ok, environment} = Environments.put(scope, "qa", %{})

    {:ok, _instance} =
      CodeMySpec.AppInstances.create(scope, %{
        environment_id: environment.id,
        port_mode: :configured,
        database_mode: :configured
      })

    assert {:error, :environment_in_use} = Environments.delete(scope, "qa")
    assert Environments.get(scope, "qa").id == environment.id
  end

  test "an unused destination can be deleted", %{scope: scope} do
    {:ok, _} = Environments.put(scope, "qa", %{})
    assert :ok = Environments.delete(scope, "qa")
    assert Environments.get(scope, "qa") == nil
  end

  test "environment device assignments stay within the active account", %{scope: scope} do
    other = full_scope_fixture()
    {:ok, own} = CodeMySpec.Devices.link_provider_machine(scope, %{name: "own-box"})
    {:ok, foreign} = CodeMySpec.Devices.link_provider_machine(other, %{name: "foreign-box"})
    assert {:ok, environment} = Environments.put(scope, "qa", %{device_id: own.id})
    assert environment.device_id == own.id
    assert {:error, changeset} = Environments.put(scope, "qa", %{device_id: foreign.id})
    assert "does not belong to this account" in errors_on(changeset).device_id
    assert Environments.get(scope, "qa").device_id == own.id
  end

  test "first deployment is recorded once", %{scope: scope} do
    {:ok, _} = Environments.put(scope, "qa", %{})
    assert :ok = Environments.mark_first_deployed(scope, "qa")
    first = Environments.get(scope, "qa").first_deployed_at
    assert %DateTime{} = first
    assert :ok = Environments.mark_first_deployed(scope, "qa")
    assert Environments.get(scope, "qa").first_deployed_at == first
  end
end
