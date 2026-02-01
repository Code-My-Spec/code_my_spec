defmodule CodeMySpec.Architecture.NamespaceProjectorTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Architecture.NamespaceProjector
  alias CodeMySpec.Components.Component

  # ============================================================================
  # Fixtures
  # ============================================================================

  defp component(attrs) do
    defaults = %{
      id: Ecto.UUID.generate(),
      name: "TestComponent",
      type: "module",
      module_name: "CodeMySpec.Test",
      description: "A test component",
      account_id: 1,
      project_id: Ecto.UUID.generate(),
      parent_component_id: nil,
      synced_at: nil,
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    struct(Component, Map.merge(defaults, attrs))
  end

  defp single_component do
    component(%{
      name: "Components",
      module_name: "CodeMySpec.Components",
      type: "context",
      description: "Component management context"
    })
  end

  defp two_level_components do
    [
      component(%{
        name: "Components",
        module_name: "CodeMySpec.Components",
        type: "context",
        description: "Component management"
      }),
      component(%{
        name: "Component",
        module_name: "CodeMySpec.Components.Component",
        type: "schema",
        description: "Component schema"
      })
    ]
  end

  defp deep_hierarchy_components do
    [
      component(%{
        name: "CodeMySpec",
        module_name: "CodeMySpec",
        type: "context",
        description: "Root namespace"
      }),
      component(%{
        name: "Components",
        module_name: "CodeMySpec.Components",
        type: "context",
        description: "Component context"
      }),
      component(%{
        name: "Sync",
        module_name: "CodeMySpec.Components.Sync",
        type: "context",
        description: "Sync subcontext"
      }),
      component(%{
        name: "FileInfo",
        module_name: "CodeMySpec.Components.Sync.FileInfo",
        type: "module",
        description: "File information"
      }),
      component(%{
        name: "Parser",
        module_name: "CodeMySpec.Components.Sync.FileInfo.Parser",
        type: "module",
        description: "Parses file info"
      }),
      component(%{
        name: "Validator",
        module_name: "CodeMySpec.Components.Sync.FileInfo.Parser.Validator",
        type: "module",
        description: "Validates parsed data"
      })
    ]
  end

  defp components_with_same_namespace do
    [
      component(%{
        name: "Components",
        module_name: "CodeMySpec.Components",
        type: "context",
        description: "Component context"
      }),
      component(%{
        name: "Component",
        module_name: "CodeMySpec.Components.Component",
        type: "schema",
        description: "Component schema"
      }),
      component(%{
        name: "ComponentRepository",
        module_name: "CodeMySpec.Components.ComponentRepository",
        type: "repository",
        description: "Component repository"
      }),
      component(%{
        name: "Dependency",
        module_name: "CodeMySpec.Components.Dependency",
        type: "schema",
        description: "Dependency schema"
      })
    ]
  end

  defp components_with_shared_prefix do
    [
      component(%{
        name: "Components",
        module_name: "CodeMySpec.Components",
        type: "context",
        description: "Component context"
      }),
      component(%{
        name: "Component",
        module_name: "CodeMySpec.Components.Component",
        type: "schema",
        description: "Component schema"
      }),
      component(%{
        name: "ComponentStatus",
        module_name: "CodeMySpec.Components.ComponentStatus",
        type: "module",
        description: "Component status"
      }),
      component(%{
        name: "Stories",
        module_name: "CodeMySpec.Stories",
        type: "context",
        description: "Story context"
      }),
      component(%{
        name: "Story",
        module_name: "CodeMySpec.Stories.Story",
        type: "schema",
        description: "Story schema"
      })
    ]
  end

  # ============================================================================
  # project/1 - Happy Path Tests
  # ============================================================================

  describe "project/1" do
    test "returns empty string for empty component list" do
      assert NamespaceProjector.project([]) == ""
    end

    test "displays single component as root without tree characters" do
      component = single_component()
      result = NamespaceProjector.project([component])

      assert result == "CodeMySpec.Components [context] Component management context"
    end

    test "builds simple two-level namespace hierarchy (e.g., CodeMySpec.Components)" do
      components = two_level_components()
      result = NamespaceProjector.project(components)

      assert result =~ "CodeMySpec"
      assert result =~ "Components [context] Component management"
      assert result =~ "Component [schema] Component schema"
    end

    test "builds deep namespace hierarchy with 5+ levels" do
      components = deep_hierarchy_components()
      result = NamespaceProjector.project(components)

      # Verify all components appear in output
      assert result =~ "CodeMySpec [context] Root namespace"
      assert result =~ "Components [context] Component context"
      assert result =~ "Sync [context] Sync subcontext"
      assert result =~ "FileInfo [module] File information"
      assert result =~ "Parser [module] Parses file info"
      assert result =~ "Validator [module] Validates parsed data"
    end

    test "shows multiple components in same namespace grouped together" do
      components = components_with_same_namespace()
      result = NamespaceProjector.project(components)

      # All components should be under the same parent namespace
      assert result =~ "Components [context] Component context"
      assert result =~ "Component [schema] Component schema"
      assert result =~ "ComponentRepository [repository] Component repository"
      assert result =~ "Dependency [schema] Dependency schema"
    end

    test "uses tree characters (├──, └──) for non-last siblings" do
      components = components_with_same_namespace()
      result = NamespaceProjector.project(components)

      # Should have tree characters for branching
      assert result =~ "├──" or result =~ "└──"
    end

    test "uses └── for last child at each level" do
      components = two_level_components()
      result = NamespaceProjector.project(components)

      # The last child should use └──
      assert result =~ "└──"
    end

    test "includes component type in brackets at leaf nodes" do
      component = single_component()
      result = NamespaceProjector.project([component])

      assert result =~ "[context]"
    end

    test "includes component description after type" do
      component = single_component()
      result = NamespaceProjector.project([component])

      assert result =~ "Component management context"
    end

    test "sorts siblings alphabetically within each namespace level" do
      # Create components in non-alphabetical order
      components = [
        component(%{
          name: "Zebra",
          module_name: "CodeMySpec.Zebra",
          description: "Last alphabetically"
        }),
        component(%{
          name: "Alpha",
          module_name: "CodeMySpec.Alpha",
          description: "First alphabetically"
        }),
        component(%{
          name: "Middle",
          module_name: "CodeMySpec.Middle",
          description: "Middle alphabetically"
        })
      ]

      result = NamespaceProjector.project(components)
      lines = String.split(result, "\n", trim: true)

      # Find positions of each component in the output
      alpha_pos = Enum.find_index(lines, &String.contains?(&1, "Alpha"))
      middle_pos = Enum.find_index(lines, &String.contains?(&1, "Middle"))
      zebra_pos = Enum.find_index(lines, &String.contains?(&1, "Zebra"))

      # Verify alphabetical order
      assert alpha_pos < middle_pos
      assert middle_pos < zebra_pos
    end

    test "handles components with same namespace prefix sharing parent nodes" do
      components = components_with_shared_prefix()
      result = NamespaceProjector.project(components)

      # Components and ComponentStatus should share the same parent
      assert result =~ "Components [context] Component context"
      assert result =~ "Component [schema] Component schema"
      assert result =~ "ComponentStatus [module] Component status"

      # Stories should be separate
      assert result =~ "Stories [context] Story context"
      assert result =~ "Story [schema] Story schema"
    end

    test "uses 2-space indentation per level" do
      components = deep_hierarchy_components()
      result = NamespaceProjector.project(components)

      lines = String.split(result, "\n", trim: true)

      # Check that indentation increases by 2 spaces per level
      # This is a basic check - actual indentation will depend on tree structure
      assert Enum.any?(lines, fn line ->
               String.match?(line, ~r/^  /)
             end)

      assert Enum.any?(lines, fn line ->
               String.match?(line, ~r/^    /)
             end)
    end
  end

  # ============================================================================
  # project/2 - Option Tests
  # ============================================================================

  describe "project/2" do
    test "respects show_types: false to hide type badges" do
      components = two_level_components()
      result = NamespaceProjector.project(components, show_types: false)

      refute result =~ "[context]"
      refute result =~ "[schema]"
    end

    test "respects show_descriptions: false to hide descriptions" do
      components = two_level_components()
      result = NamespaceProjector.project(components, show_descriptions: false)

      refute result =~ "Component management"
      refute result =~ "Component schema"
    end

    test "respects max_depth to limit tree depth" do
      components = deep_hierarchy_components()
      result = NamespaceProjector.project(components, max_depth: 3)

      # First 3 levels should appear
      assert result =~ "CodeMySpec"
      assert result =~ "Components"
      assert result =~ "Sync"

      # Deeper levels should not appear
      refute result =~ "FileInfo"
      refute result =~ "Parser"
      refute result =~ "Validator"
    end

    test "respects filter_prefix to show only matching namespace subtree" do
      components = components_with_shared_prefix()
      result = NamespaceProjector.project(components, filter_prefix: "CodeMySpec.Components")

      # Should include Components namespace and children
      assert result =~ "Components"
      assert result =~ "Component"
      assert result =~ "ComponentStatus"

      # Should not include Stories namespace
      refute result =~ "Stories"
      refute result =~ "Story"
    end

    test "combines multiple options correctly" do
      components = deep_hierarchy_components()

      result =
        NamespaceProjector.project(components,
          show_types: false,
          show_descriptions: false,
          max_depth: 2
        )

      # Should have limited depth
      assert result =~ "CodeMySpec"
      assert result =~ "Components"
      refute result =~ "Sync"

      # Should not have types or descriptions
      refute result =~ "[context]"
      refute result =~ "Root namespace"
      refute result =~ "Component context"
    end

    test "defaults to showing types and descriptions when options not specified" do
      components = two_level_components()
      result = NamespaceProjector.project(components, [])

      # Should show types
      assert result =~ "[context]"
      assert result =~ "[schema]"

      # Should show descriptions
      assert result =~ "Component management"
      assert result =~ "Component schema"
    end
  end
end
