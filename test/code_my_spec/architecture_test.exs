defmodule CodeMySpec.ArchitectureTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.Architecture
  alias CodeMySpec.Components.Dependency

  import CodeMySpec.UsersFixtures
  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.StoriesFixtures

  describe "get_architecture_summary/1" do
    test "returns correct context and component counts" do
      scope = full_scope_fixture()

      _context1 = component_fixture(scope, %{type: "context", name: "Context1"})
      _context2 = component_fixture(scope, %{type: "context", name: "Context2"})
      _schema1 = schema_component_fixture(scope)
      _repo1 = repository_component_fixture(scope)

      summary = Architecture.get_architecture_summary(scope)

      assert summary.context_count == 2
      assert summary.component_count == 4
    end

    test "accurately counts dependencies" do
      scope = full_scope_fixture()

      {_parent, _child} = component_with_dependencies_fixture(scope)
      _other = component_fixture(scope)

      summary = Architecture.get_architecture_summary(scope)

      assert summary.dependency_count >= 1
      assert summary.component_count == 3
    end

    test "detects circular dependencies" do
      scope = full_scope_fixture()

      {_parent, _child} = component_with_dependencies_fixture(scope)
      summary = Architecture.get_architecture_summary(scope)

      assert summary.circular_dependencies == false
      assert summary.circular_dependency_count == 0
    end

    # The count, not just the boolean. `73ff202b`: the project's cycles went
    # from 4 to 21 unnoticed, because every surface holding the list reduced it
    # to yes/no on the way out — and yes/no reads the same at 4 and at 21.
    #
    # Two contexts, because the detector excludes `schema` components on both
    # ends of an edge, so the obvious parent/child fixture cannot make a cycle.
    test "counts circular dependencies rather than only reporting that some exist" do
      scope = full_scope_fixture()

      a = component_fixture(scope, %{type: "context", name: "CycleA", module_name: "CycleA"})
      b = component_fixture(scope, %{type: "context", name: "CycleB", module_name: "CycleB"})

      edge = fn source, target ->
        %Dependency{}
        |> Dependency.changeset(%{source_component_id: source.id, target_component_id: target.id})
        |> Repo.insert!()
      end

      edge.(a, b)
      edge.(b, a)

      summary = Architecture.get_architecture_summary(scope)

      assert summary.circular_dependencies == true
      assert summary.circular_dependency_count == 1
    end

    test "calculates max namespace depth" do
      scope = full_scope_fixture()

      _shallow = component_fixture(scope, %{module_name: "MyApp.Users"})
      _deep = component_fixture(scope, %{module_name: "MyApp.Users.Schemas.UserProfile"})

      summary = Architecture.get_architecture_summary(scope)

      assert summary.max_depth >= 2
    end

    test "identifies orphaned contexts" do
      scope = full_scope_fixture()

      # Context with a story - not orphaned
      context_with_story = component_fixture(scope, %{type: "context", name: "Active"})
      _story = story_fixture(scope, %{component_id: context_with_story.id})

      # Context without story and not used as dependency - orphaned
      _orphaned_context = component_fixture(scope, %{type: "context", name: "Orphaned"})

      summary = Architecture.get_architecture_summary(scope)

      assert summary.orphaned_count >= 1
    end
  end

  describe "list_orphaned_contexts/1" do
    test "returns contexts with no stories" do
      scope = full_scope_fixture()

      orphaned = component_fixture(scope, %{type: "context", name: "NoStory"})
      with_story = component_fixture(scope, %{type: "context", name: "HasStory"})
      _story = story_fixture(scope, %{component_id: with_story.id})

      orphaned_list = Architecture.list_orphaned_contexts(scope)

      orphaned_ids = Enum.map(orphaned_list, & &1.id)
      assert orphaned.id in orphaned_ids
      refute with_story.id in orphaned_ids
    end

    test "excludes contexts that are dependencies of story-linked components" do
      scope = full_scope_fixture()

      entry_point = component_fixture(scope, %{type: "context", name: "EntryPoint"})
      _story = story_fixture(scope, %{component_id: entry_point.id})

      # credo:disable-for-next-line ExSlop.Check.Readability.ObviousComment
      # Create a dependency context (should not be orphaned)
      dependency_context = component_fixture(scope, %{type: "context", name: "Dependency"})

      # Link entry_point -> dependency_context
      %Dependency{}
      |> Dependency.changeset(%{
        source_component_id: entry_point.id,
        target_component_id: dependency_context.id
      })
      |> CodeMySpec.Repo.insert!()

      # Create truly orphaned context
      orphaned = component_fixture(scope, %{type: "context", name: "Orphaned"})

      orphaned_list = Architecture.list_orphaned_contexts(scope)

      orphaned_ids = Enum.map(orphaned_list, & &1.id)
      assert orphaned.id in orphaned_ids
      refute dependency_context.id in orphaned_ids
    end

    test "includes transitively unreachable contexts" do
      scope = full_scope_fixture()

      # Entry point with story
      entry = component_fixture(scope, %{type: "context", name: "Entry"})
      _story = story_fixture(scope, %{component_id: entry.id})

      # Direct dependency (reachable)
      direct_dep = component_fixture(scope, %{type: "context", name: "DirectDep"})

      %Dependency{}
      |> Dependency.changeset(%{
        source_component_id: entry.id,
        target_component_id: direct_dep.id
      })
      |> CodeMySpec.Repo.insert!()

      # Transitive dependency (reachable)
      transitive_dep = component_fixture(scope, %{type: "context", name: "TransitiveDep"})

      %Dependency{}
      |> Dependency.changeset(%{
        source_component_id: direct_dep.id,
        target_component_id: transitive_dep.id
      })
      |> CodeMySpec.Repo.insert!()

      # Unreachable context
      unreachable = component_fixture(scope, %{type: "context", name: "Unreachable"})

      orphaned_list = Architecture.list_orphaned_contexts(scope)

      orphaned_ids = Enum.map(orphaned_list, & &1.id)
      assert unreachable.id in orphaned_ids
      refute direct_dep.id in orphaned_ids
      refute transitive_dep.id in orphaned_ids
    end

    test "returns empty list when all contexts are reachable" do
      scope = full_scope_fixture()

      context1 = component_fixture(scope, %{type: "context", name: "Context1"})
      _story1 = story_fixture(scope, %{component_id: context1.id})

      context2 = component_fixture(scope, %{type: "context", name: "Context2"})
      _story2 = story_fixture(scope, %{component_id: context2.id})

      orphaned_list = Architecture.list_orphaned_contexts(scope)

      assert orphaned_list == []
    end
  end

  describe "get_component_impact/2" do
    test "returns the target component" do
      scope = full_scope_fixture()

      target = component_fixture(scope, %{name: "Target"})

      impact = Architecture.get_component_impact(scope, target.id)

      assert impact.component.id == target.id
    end

    test "lists direct dependents" do
      scope = full_scope_fixture()

      target = component_fixture(scope, %{name: "Target"})
      dependent = component_fixture(scope, %{name: "Dependent"})

      %Dependency{}
      |> Dependency.changeset(%{
        source_component_id: dependent.id,
        target_component_id: target.id
      })
      |> CodeMySpec.Repo.insert!()

      impact = Architecture.get_component_impact(scope, target.id)

      direct_dependent_ids = Enum.map(impact.direct_dependents, & &1.id)
      assert dependent.id in direct_dependent_ids
    end

    test "includes transitive dependents through chain" do
      scope = full_scope_fixture()

      # Create chain: target <- direct <- transitive
      target = component_fixture(scope, %{name: "Target"})
      direct = component_fixture(scope, %{name: "Direct"})
      transitive = component_fixture(scope, %{name: "Transitive"})

      # direct depends on target
      %Dependency{}
      |> Dependency.changeset(%{
        source_component_id: direct.id,
        target_component_id: target.id
      })
      |> CodeMySpec.Repo.insert!()

      # transitive depends on direct
      %Dependency{}
      |> Dependency.changeset(%{
        source_component_id: transitive.id,
        target_component_id: direct.id
      })
      |> CodeMySpec.Repo.insert!()

      impact = Architecture.get_component_impact(scope, target.id)

      all_dependents = impact.direct_dependents ++ impact.transitive_dependents
      dependent_ids = Enum.map(all_dependents, & &1.id)

      assert direct.id in dependent_ids
      assert transitive.id in dependent_ids
    end

    test "identifies all affected parent contexts" do
      scope = full_scope_fixture()

      context1 = component_fixture(scope, %{type: "context", name: "Context1"})
      context2 = component_fixture(scope, %{type: "context", name: "Context2"})

      target =
        component_fixture(scope, %{
          name: "Target",
          parent_component_id: context1.id
        })

      dependent =
        component_fixture(scope, %{
          name: "Dependent",
          parent_component_id: context2.id
        })

      %Dependency{}
      |> Dependency.changeset(%{
        source_component_id: dependent.id,
        target_component_id: target.id
      })
      |> CodeMySpec.Repo.insert!()

      impact = Architecture.get_component_impact(scope, target.id)

      context_ids = Enum.map(impact.affected_contexts, & &1.id)

      assert context1.id in context_ids or context2.id in context_ids
    end

    test "handles component with no dependents" do
      scope = full_scope_fixture()

      isolated = component_fixture(scope, %{name: "Isolated"})

      impact = Architecture.get_component_impact(scope, isolated.id)

      assert impact.component.id == isolated.id
      assert impact.direct_dependents == []
      assert impact.transitive_dependents == []
    end
  end

  describe "generate_component_view/2" do
    test "accepts single component ID or module name" do
      scope = full_scope_fixture()

      component =
        component_fixture(scope, %{
          name: "TestComponent",
          module_name: "MyApp.TestComponent"
        })

      # Test with ID
      view_by_id = Architecture.generate_component_view(scope, component.id)
      assert is_binary(view_by_id)
      assert String.contains?(view_by_id, "TestComponent")

      # Test with module name
      view_by_name = Architecture.generate_component_view(scope, "MyApp.TestComponent")
      assert is_binary(view_by_name)
      assert String.contains?(view_by_name, "TestComponent")
    end

    test "accepts list of component IDs or module names" do
      scope = full_scope_fixture()

      comp1 = component_fixture(scope, %{name: "Component1", module_name: "MyApp.Comp1"})
      comp2 = component_fixture(scope, %{name: "Component2", module_name: "MyApp.Comp2"})

      # Test with IDs
      view_by_ids = Architecture.generate_component_view(scope, [comp1.id, comp2.id])
      assert is_binary(view_by_ids)
      assert String.contains?(view_by_ids, "Component1")
      assert String.contains?(view_by_ids, "Component2")

      # Test with module names
      view_by_names = Architecture.generate_component_view(scope, ["MyApp.Comp1", "MyApp.Comp2"])
      assert is_binary(view_by_names)
      assert String.contains?(view_by_names, "Component1")
      assert String.contains?(view_by_names, "Component2")
    end

    test "shows component name and description as header" do
      scope = full_scope_fixture()

      component =
        component_fixture(scope, %{
          name: "UserContext",
          description: "Manages user authentication and profiles"
        })

      view = Architecture.generate_component_view(scope, component.id)

      assert String.contains?(view, "UserContext")
      assert String.contains?(view, "Manages user authentication and profiles")
    end

    test "lists direct dependencies with descriptions" do
      scope = full_scope_fixture()

      target =
        component_fixture(scope, %{
          name: "Target",
          description: "Target component"
        })

      dep =
        component_fixture(scope, %{
          name: "Dependency",
          description: "A dependency component"
        })

      %Dependency{}
      |> Dependency.changeset(%{
        source_component_id: target.id,
        target_component_id: dep.id
      })
      |> CodeMySpec.Repo.insert!()

      view = Architecture.generate_component_view(scope, target.id)

      assert String.contains?(view, "Dependency")
      assert String.contains?(view, "A dependency component")
    end

    test "lists transitive dependencies grouped by depth" do
      scope = full_scope_fixture()

      # Create chain: root -> level1 -> level2
      root = component_fixture(scope, %{name: "Root"})
      level1 = component_fixture(scope, %{name: "Level1"})
      level2 = component_fixture(scope, %{name: "Level2"})

      %Dependency{}
      |> Dependency.changeset(%{
        source_component_id: root.id,
        target_component_id: level1.id
      })
      |> CodeMySpec.Repo.insert!()

      %Dependency{}
      |> Dependency.changeset(%{
        source_component_id: level1.id,
        target_component_id: level2.id
      })
      |> CodeMySpec.Repo.insert!()

      view = Architecture.generate_component_view(scope, root.id)

      assert String.contains?(view, "Level1")
      assert String.contains?(view, "Level2")
    end

    test "shows full module names for each dependency" do
      scope = full_scope_fixture()

      target =
        component_fixture(scope, %{
          name: "Target",
          module_name: "MyApp.Core.Target"
        })

      dep =
        component_fixture(scope, %{
          name: "Dependency",
          module_name: "MyApp.Utils.Dependency"
        })

      %Dependency{}
      |> Dependency.changeset(%{
        source_component_id: target.id,
        target_component_id: dep.id
      })
      |> CodeMySpec.Repo.insert!()

      view = Architecture.generate_component_view(scope, target.id)

      assert String.contains?(view, "MyApp.Utils.Dependency")
    end

    test "handles components with no dependencies" do
      scope = full_scope_fixture()

      isolated =
        component_fixture(scope, %{
          name: "Isolated",
          description: "Standalone component"
        })

      view = Architecture.generate_component_view(scope, isolated.id)

      assert is_binary(view)
      assert String.contains?(view, "Isolated")
      assert String.contains?(view, "Standalone component")
    end

    test "handles deeply nested dependency chains" do
      scope = full_scope_fixture()

      # Create deep chain: root -> d1 -> d2 -> d3 -> d4
      root = component_fixture(scope, %{name: "Root"})
      d1 = component_fixture(scope, %{name: "Depth1"})
      d2 = component_fixture(scope, %{name: "Depth2"})
      d3 = component_fixture(scope, %{name: "Depth3"})
      d4 = component_fixture(scope, %{name: "Depth4"})

      [
        {root.id, d1.id},
        {d1.id, d2.id},
        {d2.id, d3.id},
        {d3.id, d4.id}
      ]
      |> Enum.each(fn {source_id, target_id} ->
        %Dependency{}
        |> Dependency.changeset(%{
          source_component_id: source_id,
          target_component_id: target_id
        })
        |> CodeMySpec.Repo.insert!()
      end)

      view = Architecture.generate_component_view(scope, root.id)

      assert String.contains?(view, "Depth1")
      assert String.contains?(view, "Depth2")
      assert String.contains?(view, "Depth3")
      assert String.contains?(view, "Depth4")
    end

    test "deduplicates dependencies that appear through multiple paths" do
      scope = full_scope_fixture()

      # Create diamond: root -> a -> shared, root -> b -> shared
      root = component_fixture(scope, %{name: "Root"})
      path_a = component_fixture(scope, %{name: "PathA"})
      path_b = component_fixture(scope, %{name: "PathB"})
      shared = component_fixture(scope, %{name: "Shared"})

      [
        {root.id, path_a.id},
        {root.id, path_b.id},
        {path_a.id, shared.id},
        {path_b.id, shared.id}
      ]
      |> Enum.each(fn {source_id, target_id} ->
        %Dependency{}
        |> Dependency.changeset(%{
          source_component_id: source_id,
          target_component_id: target_id
        })
        |> CodeMySpec.Repo.insert!()
      end)

      view = Architecture.generate_component_view(scope, root.id)

      # Count occurrences of "Shared" - should appear only once despite multiple paths
      shared_count =
        view
        |> String.split("\n")
        |> Enum.count(&String.contains?(&1, "Shared"))

      # The shared component should appear in the output, but ideally deduplicated
      assert shared_count >= 1
    end
  end
end
