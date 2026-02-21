defmodule CodeMySpec.ProjectCoordinatorTest do
  use CodeMySpec.DataCase

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Components
  alias CodeMySpec.ProjectCoordinator
  alias CodeMySpec.Support.TestAdapter
  alias CodeMySpec.Tests.TestRun

  @test_repo_url "https://github.com/johns10/test_phoenix_project.git"

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
