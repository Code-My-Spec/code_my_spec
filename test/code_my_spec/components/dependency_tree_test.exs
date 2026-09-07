defmodule CodeMySpec.Components.DependencyTreeTest do
  use CodeMySpecTest.DataCase, async: true
  import ExUnit.CaptureLog

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.DependencyFixtures
  import CodeMySpec.ProjectsFixtures
  import CodeMySpec.UsersFixtures
  import CodeMySpec.AccountsFixtures

  alias CodeMySpec.Components.ComponentRepository
  alias CodeMySpec.Components.DependencyTree

  setup do
    user = user_fixture()
    account = account_with_owner_fixture(user)
    scope = user_scope_fixture(user, account)
    project = project_fixture(scope)
    scope = user_scope_fixture(user, account, project)

    %{scope: scope, project: project, user: user, account: account}
  end

  describe "build/1 - multiple components" do
    test "builds nested trees for components with no dependencies", %{scope: scope} do
      comp1 = component_fixture(scope, %{name: "Component1"})
      comp2 = component_fixture(scope, %{name: "Component2"})

      components = ComponentRepository.list_components_with_dependencies(scope)
      result = DependencyTree.build(components)

      assert length(result) == 2
      assert Enum.find(result, &(&1.id == comp1.id))
      assert Enum.find(result, &(&1.id == comp2.id))

      result_comp1 = Enum.find(result, &(&1.id == comp1.id))
      result_comp2 = Enum.find(result, &(&1.id == comp2.id))

      assert result_comp1.dependencies == []
      assert result_comp2.dependencies == []
    end

    test "builds nested trees in topological order - simple chain", %{scope: scope} do
      comp1 = component_fixture(scope, %{name: "Leaf"})
      comp2 = component_fixture(scope, %{name: "Middle"})
      comp3 = component_fixture(scope, %{name: "Root"})

      dependency_fixture(scope, comp2, comp1)
      dependency_fixture(scope, comp3, comp2)

      components = ComponentRepository.list_components_with_dependencies(scope)
      result = DependencyTree.build(components)

      assert length(result) == 3

      result_root = Enum.find(result, &(&1.id == comp3.id))
      result_middle = Enum.find(result, &(&1.id == comp2.id))
      result_leaf = Enum.find(result, &(&1.id == comp1.id))

      assert result_leaf.dependencies == []
      assert length(result_middle.dependencies) == 1
      assert hd(result_middle.dependencies).id == comp1.id
      assert hd(result_middle.dependencies).dependencies == []

      assert length(result_root.dependencies) == 1
      nested_middle = hd(result_root.dependencies)
      assert nested_middle.id == comp2.id
      assert length(nested_middle.dependencies) == 1
      assert hd(nested_middle.dependencies).id == comp1.id
    end

    test "builds nested trees with multiple dependencies", %{scope: scope} do
      comp1 = component_fixture(scope, %{name: "Dep1"})
      comp2 = component_fixture(scope, %{name: "Dep2"})
      comp3 = component_fixture(scope, %{name: "Root"})

      dependency_fixture(scope, comp3, comp1)
      dependency_fixture(scope, comp3, comp2)

      components = ComponentRepository.list_components_with_dependencies(scope)
      result = DependencyTree.build(components)

      result_root = Enum.find(result, &(&1.id == comp3.id))
      assert length(result_root.dependencies) == 2

      dependency_ids = Enum.map(result_root.dependencies, & &1.id)
      assert comp1.id in dependency_ids
      assert comp2.id in dependency_ids

      Enum.each(result_root.dependencies, fn dep ->
        assert dep.dependencies == []
      end)
    end

    test "handles cycles gracefully by breaking them", %{scope: scope} do
      comp1 = component_fixture(scope, %{name: "Component1"})
      comp2 = component_fixture(scope, %{name: "Component2"})

      circular_dependency_fixture(scope, comp1, comp2)

      components = ComponentRepository.list_components_with_dependencies(scope)

      capture_log(fn ->
        result = DependencyTree.build(components)

        assert length(result) == 2

        result_comp1 = Enum.find(result, &(&1.id == comp1.id))
        result_comp2 = Enum.find(result, &(&1.id == comp2.id))

        assert result_comp1 || result_comp2
      end)
    end
  end

  describe "build/2 - single component" do
    test "builds nested tree for component with no dependencies", %{scope: scope} do
      component = component_fixture(scope)
      all_components = ComponentRepository.list_components_with_dependencies(scope)

      result = DependencyTree.build(component, all_components)

      assert result.id == component.id
      assert result.dependencies == []
    end

    test "builds nested tree for component with single dependency", %{scope: scope} do
      comp1 = component_fixture(scope, %{name: "Dependency"})
      comp2 = component_fixture(scope, %{name: "Main"})

      dependency_fixture(scope, comp2, comp1)

      all_components = ComponentRepository.list_components_with_dependencies(scope)
      main_component = Enum.find(all_components, &(&1.id == comp2.id))

      result = DependencyTree.build(main_component, all_components)

      assert result.id == comp2.id
      assert length(result.dependencies) == 1
      nested_dep = hd(result.dependencies)
      assert nested_dep.id == comp1.id
      assert nested_dep.dependencies == []
    end

    test "builds nested tree for component with nested dependencies", %{scope: scope} do
      comp1 = component_fixture(scope, %{name: "Leaf"})
      comp2 = component_fixture(scope, %{name: "Middle"})
      comp3 = component_fixture(scope, %{name: "Root"})

      dependency_fixture(scope, comp2, comp1)
      dependency_fixture(scope, comp3, comp2)

      all_components = ComponentRepository.list_components_with_dependencies(scope)
      root_component = Enum.find(all_components, &(&1.id == comp3.id))

      result = DependencyTree.build(root_component, all_components)

      assert result.id == comp3.id
      assert length(result.dependencies) == 1

      middle_dep = hd(result.dependencies)
      assert middle_dep.id == comp2.id
      assert length(middle_dep.dependencies) == 1

      leaf_dep = hd(middle_dep.dependencies)
      assert leaf_dep.id == comp1.id
      assert leaf_dep.dependencies == []
    end

    test "handles cycle detection in nested tree building", %{scope: scope} do
      comp1 = component_fixture(scope, %{name: "Component1"})
      comp2 = component_fixture(scope, %{name: "Component2"})

      circular_dependency_fixture(scope, comp1, comp2)

      all_components = ComponentRepository.list_components_with_dependencies(scope)
      component_with_deps = Enum.find(all_components, &(&1.id == comp1.id))

      capture_log(fn ->
        result = DependencyTree.build(component_with_deps, all_components)

        assert result.id == comp1.id
        assert is_list(result.dependencies)
      end)
    end

    test "handles missing dependencies gracefully", %{scope: scope} do
      comp1 = component_fixture(scope, %{name: "Main"})
      comp2 = component_fixture(scope, %{name: "Dependency"})

      dependency_fixture(scope, comp1, comp2)

      all_components = ComponentRepository.list_components_with_dependencies(scope)
      main_component = Enum.find(all_components, &(&1.id == comp1.id))

      limited_components = [main_component]

      result = DependencyTree.build(main_component, limited_components)

      assert result.id == comp1.id
      assert length(result.dependencies) == 1
      dependency = hd(result.dependencies)
      assert dependency.id == comp2.id
    end
  end

  describe "topological sort edge cases" do
    test "handles complex dependency graph with multiple roots", %{scope: scope} do
      root1 = component_fixture(scope, %{name: "Root1"})
      root2 = component_fixture(scope, %{name: "Root2"})
      shared = component_fixture(scope, %{name: "Shared"})
      leaf = component_fixture(scope, %{name: "Leaf"})

      dependency_fixture(scope, root1, shared)
      dependency_fixture(scope, root2, shared)
      dependency_fixture(scope, shared, leaf)

      components = ComponentRepository.list_components_with_dependencies(scope)
      result = DependencyTree.build(components)

      assert length(result) == 4

      result_leaf = Enum.find(result, &(&1.id == leaf.id))
      assert result_leaf.dependencies == []

      result_shared = Enum.find(result, &(&1.id == shared.id))
      assert length(result_shared.dependencies) == 1
      assert hd(result_shared.dependencies).id == leaf.id

      result_root1 = Enum.find(result, &(&1.id == root1.id))
      result_root2 = Enum.find(result, &(&1.id == root2.id))

      assert length(result_root1.dependencies) == 1
      assert length(result_root2.dependencies) == 1

      Enum.each([result_root1, result_root2], fn root ->
        nested_shared = hd(root.dependencies)
        assert nested_shared.id == shared.id
        assert length(nested_shared.dependencies) == 1
        assert hd(nested_shared.dependencies).id == leaf.id
      end)
    end

    test "handles diamond dependency pattern", %{scope: scope} do
      root = component_fixture(scope, %{name: "Root"})
      left = component_fixture(scope, %{name: "Left"})
      right = component_fixture(scope, %{name: "Right"})
      bottom = component_fixture(scope, %{name: "Bottom"})

      dependency_fixture(scope, root, left)
      dependency_fixture(scope, root, right)
      dependency_fixture(scope, left, bottom)
      dependency_fixture(scope, right, bottom)

      components = ComponentRepository.list_components_with_dependencies(scope)
      result = DependencyTree.build(components)

      assert length(result) == 4

      result_root = Enum.find(result, &(&1.id == root.id))
      assert length(result_root.dependencies) == 2

      left_deps = Enum.filter(result_root.dependencies, &(&1.id == left.id))
      right_deps = Enum.filter(result_root.dependencies, &(&1.id == right.id))

      assert length(left_deps) == 1
      assert length(right_deps) == 1

      left_dep = hd(left_deps)
      right_dep = hd(right_deps)

      assert length(left_dep.dependencies) == 1
      assert length(right_dep.dependencies) == 1
      assert hd(left_dep.dependencies).id == bottom.id
      assert hd(right_dep.dependencies).id == bottom.id
    end
  end

  describe "empty and edge cases" do
    test "handles empty component list", %{scope: _scope} do
      result = DependencyTree.build([])
      assert result == []
    end

    test "handles single component with no dependencies", %{scope: scope} do
      component = component_fixture(scope)
      components = ComponentRepository.list_components_with_dependencies(scope)

      result = DependencyTree.build(components)

      assert length(result) == 1
      assert hd(result).id == component.id
      assert hd(result).dependencies == []
    end

    test "preserves component attributes during tree building", %{scope: scope} do
      component =
        component_fixture(scope, %{
          name: "TestComponent",
          type: "context",
          module_name: "MyApp.TestComponent",
          description: "Test description"
        })

      components = ComponentRepository.list_components_with_dependencies(scope)
      result = DependencyTree.build(components)

      result_component = hd(result)
      assert result_component.name == "TestComponent"
      assert result_component.type == "context"
      assert result_component.module_name == "MyApp.TestComponent"
      assert result_component.description == "Test description"
      assert result_component.id == component.id
    end
  end
end
