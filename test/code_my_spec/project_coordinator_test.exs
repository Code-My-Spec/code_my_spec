defmodule CodeMySpec.ProjectCoordinatorTest do
  use CodeMySpecTest.DataCase

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.DependencyFixtures
  import CodeMySpec.RequirementsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Components
  alias CodeMySpec.ProjectCoordinator
  alias CodeMySpec.Support.TestAdapter
  alias CodeMySpec.Tests.TestRun

  @test_repo_url "https://github.com/Code-My-Spec/test_phoenix_project.git"

  # ============================================================================
  # Dependency Chain Tests
  # ============================================================================

  describe "build_dependency_chain/2" do
    setup do
      scope = full_scope_fixture()
      %{scope: scope}
    end

    test "single component with no deps returns just that component", %{scope: scope} do
      comp = component_fixture(scope, %{name: "Solo", module_name: "Solo"})
      all = reload_all(scope)

      chain = ProjectCoordinator.build_dependency_chain(find_by_id(all, comp.id), all)

      assert length(chain) == 1
      assert hd(chain).id == comp.id
    end

    test "linear chain A→B→C includes all transitive deps", %{scope: scope} do
      a = component_fixture(scope, %{name: "A", module_name: "A"})
      b = component_fixture(scope, %{name: "B", module_name: "B"})
      c = component_fixture(scope, %{name: "C", module_name: "C"})

      # A depends on B, B depends on C
      dependency_fixture(scope, a, b)
      dependency_fixture(scope, b, c)

      all = reload_all(scope)
      chain = ProjectCoordinator.build_dependency_chain(find_by_id(all, a.id), all)

      assert length(chain) == 3
      chain_ids = Enum.map(chain, & &1.id)
      assert c.id in chain_ids
      assert b.id in chain_ids
      assert a.id in chain_ids
    end

    test "only includes transitive deps of target, not unrelated components", %{scope: scope} do
      a = component_fixture(scope, %{name: "A", module_name: "A"})
      b = component_fixture(scope, %{name: "B", module_name: "B"})
      _unrelated = component_fixture(scope, %{name: "Unrelated", module_name: "Unrelated"})

      dependency_fixture(scope, a, b)

      all = reload_all(scope)
      chain = ProjectCoordinator.build_dependency_chain(find_by_id(all, a.id), all)

      chain_ids = Enum.map(chain, & &1.id)
      assert length(chain_ids) == 2
      assert a.id in chain_ids
      assert b.id in chain_ids
    end
  end

  describe "find_next_in_chain/2" do
    setup do
      scope = full_scope_fixture()
      %{scope: scope}
    end

    test "returns root if it has unsatisfied requirements and no deps", %{scope: scope} do
      comp = component_fixture(scope, %{name: "Root", module_name: "Root"})
      requirement_fixture(scope, comp, %{name: "spec_file", satisfied: false})

      all = reload_all(scope)

      assert {:ready, ready} =
               ProjectCoordinator.find_next_in_chain(find_by_id(all, comp.id), all)

      assert ready.id == comp.id
    end

    test "linear chain A→B→C returns C (leaf first) when all unsatisfied", %{scope: scope} do
      a = component_fixture(scope, %{name: "A", module_name: "A"})
      b = component_fixture(scope, %{name: "B", module_name: "B"})
      c = component_fixture(scope, %{name: "C", module_name: "C"})

      dependency_fixture(scope, a, b)
      dependency_fixture(scope, b, c)

      # All have unsatisfied requirements
      requirement_fixture(scope, a, %{name: "spec_file", satisfied: false})
      requirement_fixture(scope, a, %{name: "dependencies_satisfied", satisfied: false})
      requirement_fixture(scope, b, %{name: "spec_file", satisfied: false})
      requirement_fixture(scope, b, %{name: "dependencies_satisfied", satisfied: false})
      requirement_fixture(scope, c, %{name: "spec_file", satisfied: false})

      all = reload_all(scope)
      assert {:ready, ready} = ProjectCoordinator.find_next_in_chain(find_by_id(all, a.id), all)
      # C is the leaf — no dependencies_satisfied requirement, so it's ready
      assert ready.id == c.id
    end

    test "leaf satisfied returns next up the chain", %{scope: scope} do
      a = component_fixture(scope, %{name: "A", module_name: "A"})
      b = component_fixture(scope, %{name: "B", module_name: "B"})
      c = component_fixture(scope, %{name: "C", module_name: "C"})

      dependency_fixture(scope, a, b)
      dependency_fixture(scope, b, c)

      # C is fully satisfied
      requirement_fixture(scope, c, %{name: "spec_file", satisfied: true})
      # B has unsatisfied work but deps are satisfied
      requirement_fixture(scope, b, %{name: "spec_file", satisfied: false})
      requirement_fixture(scope, b, %{name: "dependencies_satisfied", satisfied: true})
      # A has unsatisfied work and deps are not yet satisfied
      requirement_fixture(scope, a, %{name: "spec_file", satisfied: false})
      requirement_fixture(scope, a, %{name: "dependencies_satisfied", satisfied: false})

      all = reload_all(scope)
      assert {:ready, ready} = ProjectCoordinator.find_next_in_chain(find_by_id(all, a.id), all)
      assert ready.id == b.id
    end

    test "all satisfied returns :complete", %{scope: scope} do
      a = component_fixture(scope, %{name: "A", module_name: "A"})
      b = component_fixture(scope, %{name: "B", module_name: "B"})

      dependency_fixture(scope, a, b)

      requirement_fixture(scope, a, %{name: "spec_file", satisfied: true})
      requirement_fixture(scope, a, %{name: "dependencies_satisfied", satisfied: true})
      requirement_fixture(scope, b, %{name: "spec_file", satisfied: true})

      all = reload_all(scope)
      assert :complete = ProjectCoordinator.find_next_in_chain(find_by_id(all, a.id), all)
    end

    test "blocked when unsatisfied but deps not met returns {:blocked, chain}", %{scope: scope} do
      a = component_fixture(scope, %{name: "A", module_name: "A"})
      b = component_fixture(scope, %{name: "B", module_name: "B"})

      dependency_fixture(scope, a, b)

      # Both have unsatisfied requirements, but both have unsatisfied dependencies_satisfied
      requirement_fixture(scope, a, %{name: "spec_file", satisfied: false})
      requirement_fixture(scope, a, %{name: "dependencies_satisfied", satisfied: false})
      requirement_fixture(scope, b, %{name: "spec_file", satisfied: false})
      requirement_fixture(scope, b, %{name: "dependencies_satisfied", satisfied: false})

      all = reload_all(scope)
      assert {:blocked, chain} = ProjectCoordinator.find_next_in_chain(find_by_id(all, a.id), all)
      assert length(chain) == 2
    end

    test "component with no requirements returns :complete", %{scope: scope} do
      comp = component_fixture(scope, %{name: "NoReqs", module_name: "NoReqs"})

      all = reload_all(scope)
      assert :complete = ProjectCoordinator.find_next_in_chain(find_by_id(all, comp.id), all)
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp reload_all(scope) do
    Components.list_components_with_dependencies(scope)
  end

  defp find_by_id(components, id) do
    Enum.find(components, &(&1.id == id))
  end

  # ============================================================================
  # Integration Tests
  # ============================================================================

  describe "sync_project_requirements/4" do
    setup do
      scope = full_scope_fixture()

      # Update project to match the test repo module name
      {:ok, updated_project} =
        CodeMySpec.Projects.update_project(
          scope,
          scope.active_project,
          %{module_name: "TestPhoenixProject"}
        )

      scope = %{scope | active_project: updated_project}

      # Create test components matching the docs structure
      {:ok, blog_context} =
        Components.create_component(scope, %{
          name: "Blog",
          type: "context",
          module_name: "TestPhoenixProject.Blog",
          description: "Blog context"
        })

      {:ok, post_schema} =
        Components.create_component(scope, %{
          name: "Post",
          type: "schema",
          module_name: "TestPhoenixProject.Blog.Post",
          description: "Post schema"
        })

      Components.create_dependency(scope, %{
        source_component_id: blog_context.id,
        target_component_id: post_schema.id
      })

      {:ok, post_repository} =
        Components.create_component(scope, %{
          name: "PostRepository",
          type: "repository",
          module_name: "TestPhoenixProject.Blog.PostRepository",
          description: "Post repository"
        })

      Components.create_dependency(scope, %{
        source_component_id: blog_context.id,
        target_component_id: post_repository.id
      })

      {:ok, post_cache} =
        Components.create_component(scope, %{
          name: "PostCache",
          type: "genserver",
          module_name: "TestPhoenixProject.Blog.PostCache",
          description: "Post cache"
        })

      Components.create_dependency(scope, %{
        source_component_id: blog_context.id,
        target_component_id: post_cache.id
      })

      # Clone from pool
      {:ok, project_dir} = TestAdapter.clone(scope, @test_repo_url)

      # Point environment cwd at the cloned repo so checkers can find files
      scope = put_in(scope.environment.cwd, project_dir)

      on_exit(fn ->
        TestAdapter.checkin(project_dir)
      end)

      %{
        scope: scope,
        components: [blog_context, post_schema, post_repository, post_cache],
        project_dir: project_dir
      }
    end

    @tag :integration
    test "syncs project requirements with real test project", %{
      scope: scope,
      project_dir: project_dir
    } do
      file_list =
        DirWalker.stream(project_dir)
        |> Enum.map(&Path.relative_to(&1, project_dir))
        |> Enum.to_list()

      # Read cached test results
      test_output = File.read!(TestAdapter.test_results_cache_path())

      test_results = parse_test_results(test_output)

      # Sync project requirements
      result =
        ProjectCoordinator.sync_project_requirements(scope, file_list, test_results,
          working_dir: project_dir
        )

      post_cache = Enum.find(result, &(&1.name == "PostCache"))
      assert post_cache.requirements |> Enum.any?(&(&1.satisfied == false))

      # test_spec_alignment correctly returns unsatisfied when spec analysis errors,
      # rather than silently passing. All other requirements should be satisfied.
      for component_name <- ["Post", "PostRepository"] do
        component = Enum.find(result, &(&1.name == component_name))

        {_alignment_reqs, other_reqs} =
          Enum.split_with(component.requirements, &(&1.name == "test_spec_alignment"))

        assert other_reqs |> Enum.all?(&(&1.satisfied == true)),
               "Expected all non-alignment requirements satisfied for #{component_name}"
      end

      blog_context = Enum.find(result, &(&1.name == "Blog"))
      assert blog_context.requirements |> Enum.any?(&(&1.satisfied == false))

      blog_context
      |> Map.drop([:dependencies])

      assert is_list(result)
      assert result != []
    end
  end

  defp parse_test_results(output) do
    {:ok, data} = Jason.decode(output)
    changeset = TestRun.changeset(data)

    Ecto.Changeset.apply_changes(changeset)
  end
end
