defmodule CodeMySpec.Architecture.OverviewProjectorTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Architecture.OverviewProjector
  alias CodeMySpec.Components.Component

  # Fixtures

  defp context_component(attrs \\ %{}) do
    defaults = %{
      id: UUID.uuid4(),
      name: "Stories",
      type: "context",
      module_name: "CodeMySpec.Stories",
      description: "Manages user stories and requirements",
      parent_component_id: nil,
      dependencies: [],
      child_components: []
    }

    struct!(Component, Map.merge(defaults, attrs))
  end

  defp module_component(attrs) do
    defaults = %{
      id: UUID.uuid4(),
      name: "Story",
      type: "schema",
      module_name: "CodeMySpec.Stories.Story",
      description: "Story schema representing user stories",
      parent_component_id: nil,
      dependencies: []
    }

    struct!(Component, Map.merge(defaults, attrs))
  end

  defp repository_component(attrs) do
    defaults = %{
      id: UUID.uuid4(),
      name: "StoryRepository",
      type: "repository",
      module_name: "CodeMySpec.Stories.StoryRepository",
      description: "Repository for story data access",
      parent_component_id: nil,
      dependencies: []
    }

    struct!(Component, Map.merge(defaults, attrs))
  end

  describe "project/1" do
    test "generates markdown with title header" do
      components = []
      result = OverviewProjector.project(components)

      assert String.starts_with?(result, "# Architecture Overview")
    end

    test "groups components by parent context" do
      context = context_component()

      child1 =
        module_component(%{
          name: "Story",
          module_name: "CodeMySpec.Stories.Story",
          parent_component_id: context.id
        })

      child2 =
        repository_component(%{
          name: "StoryRepository",
          module_name: "CodeMySpec.Stories.StoryRepository",
          parent_component_id: context.id
        })

      components = [context, child1, child2]
      result = OverviewProjector.project(components)

      assert result =~ "## Stories"
      assert result =~ "### Story"
      assert result =~ "### StoryRepository"
    end

    test "creates H2 sections for each context" do
      context1 = context_component(%{name: "Stories", module_name: "CodeMySpec.Stories"})
      context2 = context_component(%{name: "Projects", module_name: "CodeMySpec.Projects"})

      components = [context1, context2]
      result = OverviewProjector.project(components)

      assert result =~ "## Stories"
      assert result =~ "## Projects"
    end

    test "includes context descriptions" do
      context =
        context_component(%{
          name: "Stories",
          description: "Manages user stories and requirements"
        })

      components = [context]
      result = OverviewProjector.project(components)

      assert result =~ "## Stories"
      assert result =~ "Manages user stories and requirements"
    end

    test "lists components with H3 headers under their contexts" do
      context = context_component()

      child =
        module_component(%{
          name: "Story",
          parent_component_id: context.id
        })

      components = [context, child]
      result = OverviewProjector.project(components)

      assert result =~ "## Stories"
      assert result =~ "### Story"
    end

    test "includes component type in bold" do
      context = context_component()

      child =
        module_component(%{
          name: "Story",
          type: "schema",
          parent_component_id: context.id
        })

      components = [context, child]
      result = OverviewProjector.project(components)

      assert result =~ "**schema**"
      assert result =~ "**context**"
    end

    test "includes component descriptions when present" do
      context = context_component()

      child =
        module_component(%{
          name: "Story",
          description: "Story schema representing user stories",
          parent_component_id: context.id
        })

      components = [context, child]
      result = OverviewProjector.project(components)

      assert result =~ "Story schema representing user stories"
    end

    test "lists dependencies with module names" do
      dependency_component =
        module_component(%{
          name: "Dependency",
          module_name: "CodeMySpec.Components.Dependency"
        })

      component =
        module_component(%{
          name: "Component",
          module_name: "CodeMySpec.Components.Component",
          dependencies: [dependency_component]
        })

      components = [component, dependency_component]
      result = OverviewProjector.project(components)

      assert result =~ "Dependencies:"
      assert result =~ "CodeMySpec.Components.Dependency"
    end

    test "handles components with no parent in root section" do
      root_component =
        module_component(%{
          name: "RootModule",
          parent_component_id: nil
        })

      components = [root_component]
      result = OverviewProjector.project(components)

      assert result =~ "## Root Components"
      assert result =~ "### RootModule"
    end

    test "handles contexts with no child components" do
      context = context_component()

      components = [context]
      result = OverviewProjector.project(components)

      assert result =~ "## Stories"
      assert result =~ "**context**"
    end

    test "handles empty component list returning minimal markdown" do
      result = OverviewProjector.project([])

      assert String.starts_with?(result, "# Architecture Overview")
      assert String.length(result) < 100
    end

    test "handles components with no dependencies" do
      component =
        module_component(%{
          name: "SimpleModule",
          dependencies: []
        })

      components = [component]
      result = OverviewProjector.project(components)

      refute result =~ "Dependencies:"
    end

    test "sorts contexts alphabetically by name" do
      context1 = context_component(%{name: "Zebra", module_name: "CodeMySpec.Zebra"})
      context2 = context_component(%{name: "Alpha", module_name: "CodeMySpec.Alpha"})
      context3 = context_component(%{name: "Middle", module_name: "CodeMySpec.Middle"})

      components = [context1, context2, context3]
      result = OverviewProjector.project(components)

      alpha_pos = :binary.match(result, "## Alpha") |> elem(0)
      middle_pos = :binary.match(result, "## Middle") |> elem(0)
      zebra_pos = :binary.match(result, "## Zebra") |> elem(0)

      assert alpha_pos < middle_pos
      assert middle_pos < zebra_pos
    end

    test "sorts components within contexts alphabetically by name" do
      context = context_component()

      child1 =
        module_component(%{
          name: "Zebra",
          module_name: "CodeMySpec.Stories.Zebra",
          parent_component_id: context.id
        })

      child2 =
        module_component(%{
          name: "Alpha",
          module_name: "CodeMySpec.Stories.Alpha",
          parent_component_id: context.id
        })

      child3 =
        module_component(%{
          name: "Beta",
          module_name: "CodeMySpec.Stories.Beta",
          parent_component_id: context.id
        })

      components = [context, child1, child2, child3]
      result = OverviewProjector.project(components)

      alpha_pos = :binary.match(result, "### Alpha") |> elem(0)
      beta_pos = :binary.match(result, "### Beta") |> elem(0)
      zebra_pos = :binary.match(result, "### Zebra") |> elem(0)

      assert alpha_pos < beta_pos
      assert beta_pos < zebra_pos
    end

    test "handles nil descriptions gracefully" do
      component =
        module_component(%{
          name: "NoDescription",
          description: nil
        })

      components = [component]
      result = OverviewProjector.project(components)

      assert result =~ "### NoDescription"
      refute String.contains?(result, "nil")
    end

    test "preserves component attributes" do
      component =
        module_component(%{
          name: "TestModule",
          type: "service",
          module_name: "CodeMySpec.TestModule",
          description: "Test module description"
        })

      components = [component]
      result = OverviewProjector.project(components)

      assert result =~ "### TestModule"
      assert result =~ "**service**"
      assert result =~ "Test module description"
    end
  end

  describe "project/2" do
    test "includes descriptions when include_descriptions: true (default)" do
      component =
        module_component(%{
          description: "This is a detailed description"
        })

      components = [component]
      result = OverviewProjector.project(components, include_descriptions: true)

      assert result =~ "This is a detailed description"
    end

    test "excludes descriptions when include_descriptions: false" do
      component =
        module_component(%{
          description: "This should not appear"
        })

      components = [component]
      result = OverviewProjector.project(components, include_descriptions: false)

      refute result =~ "This should not appear"
    end

    test "includes dependencies when include_dependencies: true (default)" do
      dependency_component =
        module_component(%{
          name: "Dependency",
          module_name: "CodeMySpec.Dependency"
        })

      component =
        module_component(%{
          name: "Component",
          dependencies: [dependency_component]
        })

      components = [component, dependency_component]
      result = OverviewProjector.project(components, include_dependencies: true)

      assert result =~ "Dependencies:"
      assert result =~ "CodeMySpec.Dependency"
    end

    test "excludes dependencies when include_dependencies: false" do
      dependency_component =
        module_component(%{
          name: "Dependency",
          module_name: "CodeMySpec.Dependency"
        })

      component =
        module_component(%{
          name: "Component",
          dependencies: [dependency_component]
        })

      components = [component, dependency_component]
      result = OverviewProjector.project(components, include_dependencies: false)

      refute result =~ "Dependencies:"
      refute result =~ "CodeMySpec.Dependency"
    end

    test "filters to specific contexts when context_filter option provided" do
      context1 = context_component(%{name: "Stories", module_name: "CodeMySpec.Stories"})
      context2 = context_component(%{name: "Projects", module_name: "CodeMySpec.Projects"})

      child1 =
        module_component(%{
          name: "Story",
          parent_component_id: context1.id
        })

      child2 =
        module_component(%{
          name: "Project",
          parent_component_id: context2.id
        })

      components = [context1, context2, child1, child2]

      result =
        OverviewProjector.project(components, context_filter: ["CodeMySpec.Stories"])

      assert result =~ "## Stories"
      assert result =~ "### Story"
      refute result =~ "## Projects"
      refute result =~ "### Project"
    end

    test "combines multiple options correctly" do
      context = context_component(%{name: "Stories", module_name: "CodeMySpec.Stories"})

      dependency_component =
        module_component(%{
          name: "Dependency",
          module_name: "CodeMySpec.Dependency"
        })

      child =
        module_component(%{
          name: "Story",
          description: "A user story",
          parent_component_id: context.id,
          dependencies: [dependency_component]
        })

      components = [context, child, dependency_component]

      result =
        OverviewProjector.project(components,
          include_descriptions: false,
          include_dependencies: false,
          context_filter: ["CodeMySpec.Stories"]
        )

      assert result =~ "## Stories"
      assert result =~ "### Story"
      refute result =~ "A user story"
      refute result =~ "Dependencies:"
    end

    test "handles empty options list with default behavior" do
      component =
        module_component(%{
          description: "Default behavior test",
          dependencies: []
        })

      components = [component]
      result = OverviewProjector.project(components, [])

      assert result =~ "Default behavior test"
    end

    test "validates context_filter as list of context module names" do
      context = context_component(%{name: "Stories", module_name: "CodeMySpec.Stories"})

      child =
        module_component(%{
          name: "Story",
          parent_component_id: context.id
        })

      components = [context, child]

      result =
        OverviewProjector.project(components,
          context_filter: ["CodeMySpec.Stories", "CodeMySpec.Projects"]
        )

      assert result =~ "## Stories"
      assert result =~ "### Story"
    end

    test "handles context_filter matching no components" do
      context = context_component(%{name: "Stories", module_name: "CodeMySpec.Stories"})

      components = [context]
      result = OverviewProjector.project(components, context_filter: ["CodeMySpec.NonExistent"])

      assert String.starts_with?(result, "# Architecture Overview")
      refute result =~ "## Stories"
    end
  end
end
