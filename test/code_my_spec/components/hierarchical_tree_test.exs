defmodule CodeMySpec.Components.HierarchicalTreeTest do
  use ExUnit.Case
  doctest CodeMySpec.Components.HierarchicalTree
  alias CodeMySpec.Components.{Component, HierarchicalTree}

  describe "build/1" do
    test "returns empty list for empty input" do
      assert HierarchicalTree.build([]) == []
    end

    test "builds simple parent-child hierarchy" do
      parent = %Component{
        id: 1,
        name: "Components",
        module_name: "CodeMySpec.Components",
        parent_component_id: nil
      }

      child = %Component{
        id: 2,
        name: "ComponentRepository",
        module_name: "CodeMySpec.Components.ComponentRepository",
        parent_component_id: 1
      }

      components = [parent, child]
      result = HierarchicalTree.build(components)

      assert length(result) == 1
      [root] = result
      assert root.id == 1
      assert length(root.child_components) == 1
      assert hd(root.child_components).id == 2
    end

    test "builds multi-level hierarchy" do
      root = %Component{
        id: 1,
        name: "Components",
        module_name: "CodeMySpec.Components",
        parent_component_id: nil
      }

      middle = %Component{
        id: 2,
        name: "Requirements",
        module_name: "CodeMySpec.Requirements",
        parent_component_id: 1
      }

      leaf1 = %Component{
        id: 3,
        name: "Checker",
        module_name: "CodeMySpec.Requirements.Checker",
        parent_component_id: 2
      }

      leaf2 = %Component{
        id: 4,
        name: "Requirement",
        module_name: "CodeMySpec.Requirements.Requirement",
        parent_component_id: 2
      }

      components = [root, middle, leaf1, leaf2]
      result = HierarchicalTree.build(components)

      assert length(result) == 1
      [root_node] = result
      assert root_node.id == 1
      assert length(root_node.child_components) == 1

      [middle_node] = root_node.child_components
      assert middle_node.id == 2
      assert length(middle_node.child_components) == 2

      child_ids = Enum.map(middle_node.child_components, & &1.id) |> Enum.sort()
      assert child_ids == [3, 4]
    end

    test "handles multiple root components" do
      root1 = %Component{
        id: 1,
        name: "Components",
        module_name: "CodeMySpec.Components",
        parent_component_id: nil
      }

      root2 = %Component{
        id: 2,
        name: "Projects",
        module_name: "CodeMySpec.Projects",
        parent_component_id: nil
      }

      child1 = %Component{
        id: 3,
        name: "Component",
        module_name: "CodeMySpec.Components.Component",
        parent_component_id: 1
      }

      child2 = %Component{
        id: 4,
        name: "Project",
        module_name: "CodeMySpec.Projects.Project",
        parent_component_id: 2
      }

      components = [root1, root2, child1, child2]
      result = HierarchicalTree.build(components)

      assert length(result) == 2
      root_ids = Enum.map(result, & &1.id) |> Enum.sort()
      assert root_ids == [1, 2]

      components_root = Enum.find(result, &(&1.id == 1))
      projects_root = Enum.find(result, &(&1.id == 2))

      assert length(components_root.child_components) == 1
      assert hd(components_root.child_components).id == 3

      assert length(projects_root.child_components) == 1
      assert hd(projects_root.child_components).id == 4
    end
  end

  describe "build/2" do
    test "builds hierarchy for single component" do
      root = %Component{
        id: 1,
        name: "Components",
        module_name: "CodeMySpec.Components",
        parent_component_id: nil
      }

      child = %Component{
        id: 2,
        name: "Component",
        module_name: "CodeMySpec.Components.Component",
        parent_component_id: 1
      }

      all_components = [root, child]
      result = HierarchicalTree.build(root, all_components)

      assert result.id == 1
      assert length(result.child_components) == 1
      assert hd(result.child_components).id == 2
    end
  end

  describe "get_all_descendants/2" do
    test "returns empty list for leaf component" do
      leaf = %Component{
        id: 1,
        name: "Leaf",
        module_name: "CodeMySpec.Leaf",
        parent_component_id: nil
      }

      result = HierarchicalTree.get_all_descendants(leaf, [leaf])
      assert result == []
    end

    test "returns all descendants in hierarchy" do
      root = %Component{
        id: 1,
        name: "Root",
        module_name: "CodeMySpec.Root",
        parent_component_id: nil
      }

      child1 = %Component{
        id: 2,
        name: "Child1",
        module_name: "CodeMySpec.Root.Child1",
        parent_component_id: 1
      }

      child2 = %Component{
        id: 3,
        name: "Child2",
        module_name: "CodeMySpec.Root.Child2",
        parent_component_id: 1
      }

      grandchild = %Component{
        id: 4,
        name: "Grandchild",
        module_name: "CodeMySpec.Root.Child1.Grandchild",
        parent_component_id: 2
      }

      all_components = [root, child1, child2, grandchild]
      result = HierarchicalTree.get_all_descendants(root, all_components)

      descendant_ids = Enum.map(result, & &1.id) |> Enum.sort()
      assert descendant_ids == [2, 3, 4]
    end
  end

  describe "get_component_path/2" do
    test "returns single component for root" do
      root = %Component{
        id: 1,
        name: "Root",
        module_name: "CodeMySpec.Root",
        parent_component_id: nil
      }

      result = HierarchicalTree.get_component_path(root, [root])
      assert length(result) == 1
      assert hd(result).id == 1
    end

    test "returns path from root to deeply nested component" do
      root = %Component{
        id: 1,
        name: "Root",
        module_name: "CodeMySpec.Root",
        parent_component_id: nil
      }

      middle = %Component{
        id: 2,
        name: "Middle",
        module_name: "CodeMySpec.Root.Middle",
        parent_component_id: 1
      }

      leaf = %Component{
        id: 3,
        name: "Leaf",
        module_name: "CodeMySpec.Root.Middle.Leaf",
        parent_component_id: 2
      }

      all_components = [root, middle, leaf]
      result = HierarchicalTree.get_component_path(leaf, all_components)

      path_ids = Enum.map(result, & &1.id)
      assert path_ids == [1, 2, 3]
    end
  end

  describe "ancestor?/3" do
    test "returns true when component is ancestor" do
      root = %Component{
        id: 1,
        name: "Root",
        module_name: "CodeMySpec.Root",
        parent_component_id: nil
      }

      middle = %Component{
        id: 2,
        name: "Middle",
        module_name: "CodeMySpec.Root.Middle",
        parent_component_id: 1
      }

      leaf = %Component{
        id: 3,
        name: "Leaf",
        module_name: "CodeMySpec.Root.Middle.Leaf",
        parent_component_id: 2
      }

      all_components = [root, middle, leaf]

      assert HierarchicalTree.ancestor?(root, leaf, all_components) == true
      assert HierarchicalTree.ancestor?(middle, leaf, all_components) == true
    end

    test "returns false when component is not ancestor" do
      root = %Component{
        id: 1,
        name: "Root",
        module_name: "CodeMySpec.Root",
        parent_component_id: nil
      }

      sibling1 = %Component{
        id: 2,
        name: "Sibling1",
        module_name: "CodeMySpec.Root.Sibling1",
        parent_component_id: 1
      }

      sibling2 = %Component{
        id: 3,
        name: "Sibling2",
        module_name: "CodeMySpec.Root.Sibling2",
        parent_component_id: 1
      }

      all_components = [root, sibling1, sibling2]

      assert HierarchicalTree.ancestor?(sibling1, sibling2, all_components) == false
      assert HierarchicalTree.ancestor?(sibling2, sibling1, all_components) == false
    end

    test "returns false when component is same as potential ancestor" do
      component = %Component{
        id: 1,
        name: "Component",
        module_name: "CodeMySpec.Component",
        parent_component_id: nil
      }

      assert HierarchicalTree.ancestor?(component, component, [component]) == false
    end
  end
end
