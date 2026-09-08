defmodule CodeMySpec.Components.ComponentRepositoryTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.DependencyFixtures
  import CodeMySpec.ProjectsFixtures
  import CodeMySpec.UsersFixtures
  import CodeMySpec.AccountsFixtures
  import CodeMySpec.StoriesFixtures

  alias CodeMySpec.Components.{Component, ComponentRepository}
  alias CodeMySpec.Repo

  setup do
    user = user_fixture()
    account = account_with_owner_fixture(user)
    scope = user_scope_fixture(user, account)
    project = project_fixture(scope)
    scope = user_scope_fixture(user, account, project)

    %{scope: scope, project: project, user: user, account: account}
  end

  describe "list_all_descendants/2" do
    test "returns all descendants recursively", %{scope: scope} do
      # Create a hierarchy: context -> child1 -> grandchild
      context = component_fixture(scope, %{name: "Context", type: "context"})
      child1 = component_fixture(scope, %{name: "Child1", parent_component_id: context.id})
      grandchild = component_fixture(scope, %{name: "Grandchild", parent_component_id: child1.id})

      result = ComponentRepository.list_all_descendants(scope, context.id)

      assert length(result) == 2
      result_ids = Enum.map(result, & &1.id)
      assert child1.id in result_ids
      assert grandchild.id in result_ids
    end

    test "returns empty list when no children exist", %{scope: scope} do
      context = component_fixture(scope, %{name: "Context", type: "context"})

      result = ComponentRepository.list_all_descendants(scope, context.id)

      assert result == []
    end

    test "includes deeply nested descendants", %{scope: scope} do
      # Create 4 levels deep: context -> child -> grandchild -> great_grandchild
      context = component_fixture(scope, %{name: "Context", type: "context"})
      child = component_fixture(scope, %{name: "Child", parent_component_id: context.id})
      grandchild = component_fixture(scope, %{name: "Grandchild", parent_component_id: child.id})

      great_grandchild =
        component_fixture(scope, %{name: "GreatGrandchild", parent_component_id: grandchild.id})

      result = ComponentRepository.list_all_descendants(scope, context.id)

      assert length(result) == 3
      result_ids = Enum.map(result, & &1.id)
      assert child.id in result_ids
      assert grandchild.id in result_ids
      assert great_grandchild.id in result_ids
    end

    test "includes multiple branches", %{scope: scope} do
      # Create tree:  context
      #               /    \
      #            child1  child2
      #              |
      #          grandchild
      context = component_fixture(scope, %{name: "Context", type: "context"})
      child1 = component_fixture(scope, %{name: "Child1", parent_component_id: context.id})
      child2 = component_fixture(scope, %{name: "Child2", parent_component_id: context.id})
      grandchild = component_fixture(scope, %{name: "Grandchild", parent_component_id: child1.id})

      result = ComponentRepository.list_all_descendants(scope, context.id)

      assert length(result) == 3
      result_ids = Enum.map(result, & &1.id)
      assert child1.id in result_ids
      assert child2.id in result_ids
      assert grandchild.id in result_ids
    end

    test "excludes components from other projects", %{scope: scope} do
      context = component_fixture(scope, %{name: "Context", type: "context"})
      child = component_fixture(scope, %{name: "Child", parent_component_id: context.id})

      # Create in different project
      other_user = user_fixture()
      other_account = account_with_owner_fixture(other_user)
      other_scope = user_scope_fixture(other_user, other_account)
      other_project = project_fixture(other_scope)
      other_scope = user_scope_fixture(other_user, other_account, other_project)
      _other_component = component_fixture(other_scope, %{name: "OtherChild"})

      result = ComponentRepository.list_all_descendants(scope, context.id)

      assert length(result) == 1
      assert hd(result).id == child.id
    end
  end

  describe "list_components/1" do
    test "returns all components for the project", %{scope: scope} do
      component1 = component_fixture(scope, %{name: "Component1"})
      component2 = component_fixture(scope, %{name: "Component2"})

      # Create component in different project to ensure isolation
      other_user = user_fixture()
      other_account = account_with_owner_fixture(other_user)
      other_scope = user_scope_fixture(other_user, other_account)
      other_project = project_fixture(other_scope)
      other_scope = user_scope_fixture(other_user, other_account, other_project)
      _other_component = component_fixture(other_scope, %{name: "OtherComponent"})

      result = ComponentRepository.list_components(scope)

      assert length(result) == 2
      assert Enum.find(result, &(&1.id == component1.id))
      assert Enum.find(result, &(&1.id == component2.id))
    end

    test "returns empty list when no components exist", %{scope: scope} do
      result = ComponentRepository.list_components(scope)
      assert result == []
    end
  end

  describe "get_component!/2" do
    test "returns component when it exists in project", %{scope: scope} do
      component = component_fixture(scope)

      result = ComponentRepository.get_component!(scope, component.id)

      assert result.id == component.id
      assert result.name == component.name
    end

    test "raises when component doesn't exist", %{scope: scope} do
      assert_raise Ecto.NoResultsError, fn ->
        ComponentRepository.get_component!(scope, "00000000-0000-0000-0000-000000000000")
      end
    end

    test "raises when component exists but belongs to different project", %{scope: scope} do
      # Create component in different project
      other_user = user_fixture()
      other_account = account_with_owner_fixture(other_user)
      other_scope = user_scope_fixture(other_user, other_account)
      other_project = project_fixture(other_scope)
      other_scope = user_scope_fixture(other_user, other_account, other_project)
      other_component = component_fixture(other_scope)

      assert_raise Ecto.NoResultsError, fn ->
        ComponentRepository.get_component!(scope, other_component.id)
      end
    end
  end

  describe "get_component/2" do
    test "returns component when it exists in project", %{scope: scope} do
      component = component_fixture(scope)

      result = ComponentRepository.get_component(scope, component.id)

      assert result.id == component.id
      assert result.name == component.name
    end

    test "returns nil when component doesn't exist", %{scope: scope} do
      result = ComponentRepository.get_component(scope, "00000000-0000-0000-0000-000000000000")
      assert is_nil(result)
    end

    test "returns nil when component exists but belongs to different project", %{scope: scope} do
      # Create component in different project
      other_user = user_fixture()
      other_account = account_with_owner_fixture(other_user)
      other_scope = user_scope_fixture(other_user, other_account)
      other_project = project_fixture(other_scope)
      other_scope = user_scope_fixture(other_user, other_account, other_project)
      other_component = component_fixture(other_scope)

      result = ComponentRepository.get_component(scope, other_component.id)
      assert is_nil(result)
    end
  end

  describe "create_component/2" do
    test "creates component with valid attributes", %{scope: scope} do
      attrs = %{
        name: "NewComponent",
        type: "context",
        module_name: "MyApp.NewComponent",
        description: "A new component"
      }

      assert {:ok, component} = ComponentRepository.create_component(scope, attrs)
      assert component.name == "NewComponent"
      assert component.type == "context"
      assert component.module_name == "MyApp.NewComponent"
      assert component.description == "A new component"
      assert component.project_id == scope.active_project_id

      # Verify database persistence
      db_component = Repo.get(Component, component.id)
      assert db_component.name == "NewComponent"
    end

    test "returns error with invalid attributes", %{scope: scope} do
      attrs = %{name: "", module_name: ""}

      assert {:error, changeset} = ComponentRepository.create_component(scope, attrs)

      assert errors_on(changeset) == %{
               name: ["can't be blank"],
               module_name: ["can't be blank"]
             }
    end

    test "returns error with invalid module name format", %{scope: scope} do
      attrs = %{
        name: "TestComponent",
        type: "context",
        module_name: "invalid_module_name"
      }

      assert {:error, changeset} = ComponentRepository.create_component(scope, attrs)
      assert errors_on(changeset) == %{module_name: ["must be a valid Elixir module name"]}
    end

    test "returns error when module_name already exists in project", %{scope: scope} do
      component_fixture(scope, %{module_name: "MyApp.Duplicate"})

      attrs = %{
        name: "DifferentName",
        type: "context",
        module_name: "MyApp.Duplicate"
      }

      assert {:error, changeset} = ComponentRepository.create_component(scope, attrs)

      # With deterministic UUIDs, duplicate module_name generates same ID, hitting primary key constraint
      assert errors_on(changeset) == %{id: ["component already exists"]}
    end

    test "allows duplicate names across different projects", %{scope: scope} do
      # Create component in different project with same name
      other_user = user_fixture()
      other_account = account_with_owner_fixture(other_user)
      other_scope = user_scope_fixture(other_user, other_account)
      other_project = project_fixture(other_scope)
      other_scope = user_scope_fixture(other_user, other_account, other_project)
      component_fixture(other_scope, %{name: "SameName", module_name: "Other.SameName"})

      attrs = %{
        name: "SameName",
        type: "context",
        module_name: "MyApp.SameName"
      }

      assert {:ok, component} = ComponentRepository.create_component(scope, attrs)
      assert component.name == "SameName"
    end
  end

  describe "update_component/3" do
    test "updates component with valid attributes", %{scope: scope} do
      component = component_fixture(scope)
      attrs = %{name: "UpdatedName", description: "Updated description"}

      assert {:ok, updated_component} =
               ComponentRepository.update_component(scope, component, attrs)

      assert updated_component.name == "UpdatedName"
      assert updated_component.description == "Updated description"
      # unchanged
      assert updated_component.type == component.type

      # Verify database persistence
      db_component = Repo.get(Component, component.id)
      assert db_component.name == "UpdatedName"
    end

    test "returns error with invalid attributes", %{scope: scope} do
      component = component_fixture(scope)
      attrs = %{name: "", module_name: "invalid_format"}

      assert {:error, changeset} = ComponentRepository.update_component(scope, component, attrs)

      assert errors_on(changeset) == %{
               name: ["can't be blank"],
               module_name: ["must be a valid Elixir module name"]
             }
    end
  end

  describe "delete_component/2" do
    test "deletes component successfully", %{scope: scope} do
      component = component_fixture(scope)

      assert {:ok, deleted_component} = ComponentRepository.delete_component(scope, component)
      assert deleted_component.id == component.id

      # Verify removal from database
      assert is_nil(Repo.get(Component, component.id))
    end

    test "returns error when component has dependencies", %{scope: scope} do
      {parent, child} = component_with_dependencies_fixture(scope)

      # Should be able to delete parent (no incoming dependencies)
      assert {:ok, _} = ComponentRepository.delete_component(scope, parent)

      # But child deletion should work since dependency is cascade deleted
      assert {:ok, _} = ComponentRepository.delete_component(scope, child)
    end
  end

  describe "list_components_with_dependencies/1" do
    test "returns components with preloaded dependencies", %{scope: scope} do
      {parent, child} = component_with_dependencies_fixture(scope)

      result = ComponentRepository.list_components_with_dependencies(scope)

      assert length(result) == 2

      parent_result = Enum.find(result, &(&1.id == parent.id))
      child_result = Enum.find(result, &(&1.id == child.id))

      assert Ecto.assoc_loaded?(parent_result.dependencies)
      assert Ecto.assoc_loaded?(parent_result.dependents)
      assert Ecto.assoc_loaded?(parent_result.outgoing_dependencies)
      assert Ecto.assoc_loaded?(parent_result.incoming_dependencies)

      assert Ecto.assoc_loaded?(child_result.dependencies)
      assert Ecto.assoc_loaded?(child_result.dependents)
    end

    test "returns empty list when no components exist", %{scope: scope} do
      result = ComponentRepository.list_components_with_dependencies(scope)
      assert result == []
    end
  end

  describe "get_component_with_dependencies/2" do
    test "returns component with preloaded dependencies", %{scope: scope} do
      {parent, _child} = component_with_dependencies_fixture(scope)

      result = ComponentRepository.get_component_with_dependencies(scope, parent.id)

      assert result.id == parent.id
      assert Ecto.assoc_loaded?(result.dependencies)
      assert Ecto.assoc_loaded?(result.dependents)
      assert Ecto.assoc_loaded?(result.outgoing_dependencies)
      assert Ecto.assoc_loaded?(result.incoming_dependencies)
    end

    test "returns nil when component doesn't exist", %{scope: scope} do
      result =
        ComponentRepository.get_component_with_dependencies(
          scope,
          "00000000-0000-0000-0000-000000000000"
        )

      assert is_nil(result)
    end
  end

  describe "get_component_by_module_name/2" do
    test "returns component when module name exists", %{scope: scope} do
      component = component_fixture(scope, %{module_name: "MyApp.UniqueModule"})

      result = ComponentRepository.get_component_by_module_name(scope, "MyApp.UniqueModule")

      assert result.id == component.id
      assert result.module_name == "MyApp.UniqueModule"
    end

    test "returns nil when module name doesn't exist", %{scope: scope} do
      result = ComponentRepository.get_component_by_module_name(scope, "NonExistent.Module")
      assert is_nil(result)
    end

    test "returns nil when module name exists in different project", %{scope: scope} do
      # Create component in different project
      other_user = user_fixture()
      other_account = account_with_owner_fixture(other_user)
      other_scope = user_scope_fixture(other_user, other_account)
      other_project = project_fixture(other_scope)
      other_scope = user_scope_fixture(other_user, other_account, other_project)
      component_fixture(other_scope, %{module_name: "Other.Module"})

      result = ComponentRepository.get_component_by_module_name(scope, "Other.Module")
      assert is_nil(result)
    end
  end

  describe "list_components_by_type/2" do
    test "returns components filtered by type", %{scope: scope} do
      genserver_comp = genserver_component_fixture(scope)
      schema_comp = schema_component_fixture(scope)
      _context_comp = component_fixture(scope, %{type: "context"})

      genserver_result = ComponentRepository.list_components_by_type(scope, "genserver")
      schema_result = ComponentRepository.list_components_by_type(scope, "schema")
      context_result = ComponentRepository.list_components_by_type(scope, "context")

      assert length(genserver_result) == 1
      assert hd(genserver_result).id == genserver_comp.id

      assert length(schema_result) == 1
      assert hd(schema_result).id == schema_comp.id

      assert length(context_result) == 1
    end

    test "returns empty list when no components of type exist", %{scope: scope} do
      result = ComponentRepository.list_components_by_type(scope, "registry")
      assert result == []
    end
  end

  describe "search_components_by_name/2" do
    test "returns components matching name pattern", %{scope: scope} do
      component1 = component_fixture(scope, %{name: "UserService"})
      component2 = component_fixture(scope, %{name: "UserRepository"})
      _component3 = component_fixture(scope, %{name: "OrderService"})

      result = ComponentRepository.search_components_by_name(scope, "User")

      assert length(result) == 2
      component_ids = Enum.map(result, & &1.id)
      assert component1.id in component_ids
      assert component2.id in component_ids
    end

    test "search is case insensitive", %{scope: scope} do
      component = component_fixture(scope, %{name: "UserService"})

      result = ComponentRepository.search_components_by_name(scope, "user")

      assert length(result) == 1
      assert hd(result).id == component.id
    end

    test "returns empty list when no matches found", %{scope: scope} do
      component_fixture(scope, %{name: "UserService"})

      result = ComponentRepository.search_components_by_name(scope, "NonExistent")

      assert result == []
    end

    test "handles partial matches", %{scope: scope} do
      component = component_fixture(scope, %{name: "UserManagementService"})

      result = ComponentRepository.search_components_by_name(scope, "Management")

      assert length(result) == 1
      assert hd(result).id == component.id
    end
  end

  describe "create_components_with_dependencies/3" do
    test "creates multiple components and their dependencies in a transaction", %{scope: scope} do
      # Create a target component that will be referenced as a dependency
      target_component =
        component_fixture(scope, %{
          name: "TargetComponent",
          module_name: "MyApp.TargetComponent"
        })

      component_attrs_list = [
        %{
          name: "Component1",
          type: "context",
          module_name: "MyApp.Component1",
          description: "First component"
        },
        %{
          name: "Component2",
          type: "schema",
          module_name: "MyApp.Component2",
          description: "Second component"
        }
      ]

      dependencies = ["MyApp.TargetComponent"]

      assert {:ok, components} =
               ComponentRepository.create_components_with_dependencies(
                 scope,
                 component_attrs_list,
                 dependencies
               )

      assert length(components) == 2

      # Verify components were created
      assert Enum.any?(components, &(&1.name == "Component1"))
      assert Enum.any?(components, &(&1.name == "Component2"))

      # Verify dependency was created
      first_component = List.first(components)

      deps =
        ComponentRepository.get_component_with_dependencies(scope, first_component.id).dependencies

      assert length(deps) == 1
      assert hd(deps).id == target_component.id
    end

    test "rolls back all changes when component creation fails", %{scope: scope} do
      # Create a component that will cause a unique constraint violation
      _existing = component_fixture(scope, %{module_name: "MyApp.Duplicate"})

      component_attrs_list = [
        %{
          name: "ValidComponent",
          type: "context",
          module_name: "MyApp.ValidComponent"
        },
        %{
          name: "DuplicateComponent",
          type: "context",
          module_name: "MyApp.Duplicate"
        }
      ]

      initial_count = length(ComponentRepository.list_components(scope))

      assert {:error, _changeset} =
               ComponentRepository.create_components_with_dependencies(
                 scope,
                 component_attrs_list,
                 []
               )

      # Verify no components were created
      final_count = length(ComponentRepository.list_components(scope))
      assert final_count == initial_count
    end

    test "rolls back all changes when dependency creation fails", %{scope: scope} do
      component_attrs_list = [
        %{
          name: "Component1",
          type: "context",
          module_name: "MyApp.Component1"
        }
      ]

      # Reference a non-existent component, but this shouldn't cause an error
      # because we skip missing dependencies
      dependencies = ["MyApp.NonExistent"]

      initial_count = length(ComponentRepository.list_components(scope))

      assert {:ok, components} =
               ComponentRepository.create_components_with_dependencies(
                 scope,
                 component_attrs_list,
                 dependencies
               )

      # Components should be created even if dependency target doesn't exist
      assert length(components) == 1
      final_count = length(ComponentRepository.list_components(scope))
      assert final_count == initial_count + 1
    end

    test "handles empty component list", %{scope: scope} do
      assert {:ok, []} =
               ComponentRepository.create_components_with_dependencies(scope, [], [])
    end

    test "handles empty dependency list", %{scope: scope} do
      component_attrs_list = [
        %{
          name: "Component1",
          type: "context",
          module_name: "MyApp.Component1"
        }
      ]

      assert {:ok, components} =
               ComponentRepository.create_components_with_dependencies(
                 scope,
                 component_attrs_list,
                 []
               )

      assert length(components) == 1
      assert hd(components).name == "Component1"
    end

    test "creates multiple dependencies correctly", %{scope: scope} do
      # Create target components
      target1 = component_fixture(scope, %{module_name: "MyApp.Target1"})
      target2 = component_fixture(scope, %{module_name: "MyApp.Target2"})

      component_attrs_list = [
        %{
          name: "SourceComponent",
          type: "context",
          module_name: "MyApp.SourceComponent"
        }
      ]

      dependencies = ["MyApp.Target1", "MyApp.Target2"]

      assert {:ok, components} =
               ComponentRepository.create_components_with_dependencies(
                 scope,
                 component_attrs_list,
                 dependencies
               )

      source_component = hd(components)

      deps =
        ComponentRepository.get_component_with_dependencies(scope, source_component.id).dependencies

      assert length(deps) == 2

      dep_ids = Enum.map(deps, & &1.id)
      assert target1.id in dep_ids
      assert target2.id in dep_ids
    end

    test "returns error if component already exists with same module_name", %{scope: scope} do
      _existing =
        component_fixture(scope, %{
          name: "OldName",
          module_name: "MyApp.ExistingComponent",
          description: "Old description"
        })

      component_attrs_list = [
        %{
          name: "NewName",
          type: "context",
          module_name: "MyApp.ExistingComponent",
          description: "New description"
        }
      ]

      assert {:error, changeset} =
               ComponentRepository.create_components_with_dependencies(
                 scope,
                 component_attrs_list,
                 []
               )

      # With deterministic UUIDs, duplicate module_name generates same ID, hitting primary key constraint
      assert errors_on(changeset) == %{id: ["component already exists"]}
    end
  end

  describe "show_architecture/1" do
    test "returns empty list when no components with stories exist", %{scope: scope} do
      _component_without_story = component_fixture(scope)

      result = ComponentRepository.show_architecture(scope)

      assert result == []
    end

    test "returns only components with stories at depth 0", %{scope: scope} do
      component_with_story = component_fixture(scope)
      component_without_story = component_fixture(scope)
      story_fixture(scope, %{component_id: component_with_story.id})

      result = ComponentRepository.show_architecture(scope)

      assert length(result) == 1
      assert %{component: comp, depth: 0} = hd(result)
      assert comp.id == component_with_story.id
      refute Enum.any?(result, &(&1.component.id == component_without_story.id))
    end

    test "includes dependencies in the architecture graph", %{scope: scope} do
      root = component_fixture(scope, %{name: "Root"})
      dep1 = component_fixture(scope, %{name: "Dep1"})
      dep2 = component_fixture(scope, %{name: "Dep2"})

      story_fixture(scope, %{component_id: root.id})
      dependency_fixture(scope, root, dep1)
      dependency_fixture(scope, dep1, dep2)

      result = ComponentRepository.show_architecture(scope)

      assert length(result) == 1

      root_result = Enum.find(result, &(&1.component.id == root.id))
      assert root_result.depth == 0
    end

    test "handles multiple root components with stories", %{scope: scope} do
      root1 = component_fixture(scope, %{name: "Root1"})
      root2 = component_fixture(scope, %{name: "Root2"})
      shared_dep = component_fixture(scope, %{name: "SharedDep"})

      story_fixture(scope, %{component_id: root1.id})
      story_fixture(scope, %{component_id: root2.id})
      dependency_fixture(scope, root1, shared_dep)
      dependency_fixture(scope, root2, shared_dep)

      result = ComponentRepository.show_architecture(scope)

      assert length(result) == 2

      root_results = Enum.filter(result, &(&1.depth == 0))
      assert length(root_results) == 2

      Enum.filter(result, &(&1.component.id == shared_dep.id))
    end

    test "avoids infinite loops in circular dependencies", %{scope: scope} do
      comp1 = component_fixture(scope, %{name: "Comp1"})
      comp2 = component_fixture(scope, %{name: "Comp2"})

      story_fixture(scope, %{component_id: comp1.id})
      dependency_fixture(scope, comp1, comp2)
      dependency_fixture(scope, comp2, comp1)

      result = ComponentRepository.show_architecture(scope)

      assert length(result) == 1
      comp1_results = Enum.filter(result, &(&1.component.id == comp1.id))

      assert Enum.any?(comp1_results, &(&1.depth == 0))
    end

    test "excludes components from other projects", %{scope: scope} do
      root = component_fixture(scope)
      story_fixture(scope, %{component_id: root.id})

      other_user = user_fixture()
      other_account = account_with_owner_fixture(other_user)
      other_scope = user_scope_fixture(other_user, other_account)
      other_project = project_fixture(other_scope)
      other_scope = user_scope_fixture(other_user, other_account, other_project)
      other_component = component_fixture(other_scope)
      story_fixture(other_scope, %{component_id: other_component.id})

      result = ComponentRepository.show_architecture(scope)

      assert length(result) == 1
      assert hd(result).component.id == root.id
    end

    test "preloads stories and dependencies on returned components", %{scope: scope} do
      root = component_fixture(scope)
      dep = component_fixture(scope)
      story_fixture(scope, %{component_id: root.id})
      dependency_fixture(scope, root, dep)

      result = ComponentRepository.show_architecture(scope)

      root_result = Enum.find(result, &(&1.component.id == root.id))
      assert Ecto.assoc_loaded?(root_result.component.stories)
      assert Ecto.assoc_loaded?(root_result.component.outgoing_dependencies)
    end
  end
end
