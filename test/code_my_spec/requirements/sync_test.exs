defmodule CodeMySpec.Requirements.SyncTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.Components
  alias CodeMySpec.Requirements.Sync
  alias CodeMySpec.Repo

  import CodeMySpec.UsersFixtures
  import CodeMySpec.ComponentsFixtures

  setup do
    scope = full_scope_fixture()
    {:ok, scope: scope}
  end

  describe "sync_requirements/6" do
    test "basic sync with changed components", %{scope: scope} do
      # Create a simple component
      _accounts = component_fixture(scope, %{module_name: "MyApp.Accounts", type: "context"})

      # Load components with required associations
      components = Components.list_components(scope) |> Repo.preload([:project])

      # Mark first component as changed
      changed_ids = MapSet.new([hd(components).id])

      # Call sync_requirements with minimal setup
      result = Sync.sync_requirements(scope, components, changed_ids, [], [], [])

      # Should return list of components
      assert is_list(result)
      assert length(result) == 1
    end

    test "force option syncs all components", %{scope: scope} do
      # Create components
      _accounts = component_fixture(scope, %{module_name: "MyApp.Accounts", type: "context"})
      _blog = component_fixture(scope, %{module_name: "MyApp.Blog", type: "context"})

      # Load components
      components = Components.list_components(scope) |> Repo.preload([:project])

      # Empty changed set but force=true
      changed_ids = MapSet.new()

      # Should process all components because of force flag
      result = Sync.sync_requirements(scope, components, changed_ids, [], [], force: true)

      assert is_list(result)
      assert length(result) == 2
    end
  end

  describe "sync_all_requirements/3" do
    test "syncs requirements for all components", %{scope: scope} do
      # Create components
      _accounts = component_fixture(scope, %{module_name: "MyApp.Accounts", type: "context"})

      # Load and sync
      components = Components.list_components(scope) |> Repo.preload([:project])
      result = Sync.sync_all_requirements(components, scope)

      # Should return list with requirements
      assert is_list(result)
      assert length(result) == 1
    end
  end
end
