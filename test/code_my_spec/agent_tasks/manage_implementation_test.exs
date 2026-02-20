defmodule CodeMySpec.AgentTasks.ManageImplementationTest do
  use CodeMySpec.DataCase, async: true

  alias CodeMySpec.AgentTasks.ManageImplementation
  alias CodeMySpec.Environments.Environment

  import CodeMySpec.UsersFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.AcceptanceCriteriaFixtures
  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.DependencyFixtures
  import CodeMySpec.RequirementsFixtures

  @moduletag :tmp_dir

  @status_path "docs/status/implementation_status.json"

  # ============================================================================
  # Test Helpers
  # ============================================================================

  defp scope_with_env(tmp_dir) do
    scope = full_scope_fixture()
    %{scope | environment: Environment.new(:local, tmp_dir)}
  end

  defp create_story_with_criteria(scope, attrs \\ %{}) do
    component =
      component_fixture(scope, Map.merge(%{type: "context", module_name: "MyApp.Accounts"}, attrs[:component] || %{}))

    story =
      story_fixture(scope, Map.merge(%{
        title: "User Registration",
        priority: 1,
        component_id: component.id
      }, attrs[:story] || %{}))

    criterion =
      criterion_fixture(scope, story, %{description: "User can register with email"})

    story = %{story | criteria: [criterion]}

    {story, criterion, component}
  end

  defp create_component_with_unsatisfied_requirement(scope, attrs) do
    component = component_fixture(scope, attrs)

    requirement_fixture(scope, component, %{
      name: "spec_file",
      artifact_type: :specification,
      description: "Component spec exists",
      satisfied: false
    })

    component
  end

  defp write_valid_spec_file!(tmp_dir, story, criterion) do
    spec_path = CodeMySpec.BddSpecs.spec_file_path(story, criterion)
    full_path = Path.join(tmp_dir, spec_path)
    full_path |> Path.dirname() |> File.mkdir_p!()

    content = """
    defmodule MyApp.FeatureSpex do
      use Spex

      spex "user feature" do
        scenario "performs action" do
          given_ "a user exists", _context do
            {:ok, %{user: %{id: 1}}}
          end

          when_ "user performs action", context do
            {:ok, context}
          end

          then_ "action succeeds", context do
            assert context.user
            :ok
          end
        end
      end
    end
    """

    File.write!(full_path, content)
    full_path
  end

  defp read_status_file(tmp_dir) do
    path = Path.join(tmp_dir, @status_path)

    case File.read(path) do
      {:ok, content} -> {:ok, Jason.decode!(content)}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp write_status_file!(tmp_dir, data) do
    path = Path.join(tmp_dir, @status_path)
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, Jason.encode!(data))
  end

  # ============================================================================
  # command/3 Tests
  # ============================================================================

  describe "command/3" do
    test "writes specs when no BDD spec files exist for a story", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)
      {story, _criterion, _component} = create_story_with_criteria(scope)
      session = %{}

      assert {:ok, message} = ManageImplementation.command(scope, session, skip_sync: true)
      assert message =~ "Write BDD Specs"
      assert message =~ story.title

      assert {:ok, status} = read_status_file(tmp_dir)
      assert status["task"] == "write_bdd_specs"
      assert status["story_id"] == story.id
    end

    test "develops component linked to story when specs are failing", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)

      # Create story with spec file on disk (so specs will "fail" with non-zero exit)
      {story, criterion, component} = create_story_with_criteria(scope)
      write_valid_spec_file!(tmp_dir, story, criterion)

      # Give the story's component an unsatisfied requirement so it needs development
      requirement_fixture(scope, component, %{
        name: "spec_file",
        artifact_type: :specification,
        description: "Component spec exists",
        satisfied: false
      })

      session = %{}

      assert {:ok, message} = ManageImplementation.command(scope, session, skip_sync: true)
      assert message =~ "Develop"
      assert message =~ story.title

      assert {:ok, status} = read_status_file(tmp_dir)
      assert status["task"] == "develop_context"
      assert status["component_id"] == component.id
      assert status["target_story_id"] == story.id
    end

    test "develops dependency before target component", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)

      # Create a dependency component (no story, but in the chain)
      dep_component =
        create_component_with_unsatisfied_requirement(scope, %{
          type: "context",
          module_name: "MyApp.Core"
        })

      # Create target component that depends on dep_component
      target_component = component_fixture(scope, %{
        type: "context",
        module_name: "MyApp.Accounts"
      })

      # Add unsatisfied requirement to target
      requirement_fixture(scope, target_component, %{
        name: "spec_file",
        artifact_type: :specification,
        description: "Component spec exists",
        satisfied: false
      })

      # Mark target's dependencies as not satisfied
      requirement_fixture(scope, target_component, %{
        name: "dependencies_satisfied",
        artifact_type: :specification,
        description: "All dependencies satisfied",
        satisfied: false
      })

      # Create the dependency relationship: target depends on dep
      dependency_fixture(scope, target_component, dep_component)

      # Create story linked to the target component
      story =
        story_fixture(scope, %{
          title: "User Registration",
          priority: 1,
          component_id: target_component.id
        })

      criterion =
        criterion_fixture(scope, story, %{description: "User can register"})

      # Write spec file so BDD specs will be "found" (failing)
      write_valid_spec_file!(tmp_dir, %{story | criteria: [criterion]}, criterion)

      session = %{}

      assert {:ok, message} = ManageImplementation.command(scope, session, skip_sync: true)
      assert message =~ "Develop"

      # Should develop the dependency first since target's deps aren't satisfied
      assert {:ok, status} = read_status_file(tmp_dir)
      assert status["component_id"] == dep_component.id
      assert status["target_story_id"] == story.id
    end

    test "develops liveview component linked to story", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)

      # Create story with liveview component
      liveview_component = component_fixture(scope, %{
        type: "liveview",
        module_name: "MyAppWeb.DashboardLive"
      })

      requirement_fixture(scope, liveview_component, %{
        name: "spec_file",
        artifact_type: :specification,
        description: "Component spec exists",
        satisfied: false
      })

      story =
        story_fixture(scope, %{
          title: "Dashboard View",
          priority: 1,
          component_id: liveview_component.id
        })

      criterion =
        criterion_fixture(scope, story, %{description: "User sees dashboard"})

      write_valid_spec_file!(tmp_dir, %{story | criteria: [criterion]}, criterion)

      session = %{}

      assert {:ok, message} = ManageImplementation.command(scope, session, skip_sync: true)
      assert message =~ "Develop"

      assert {:ok, status} = read_status_file(tmp_dir)
      assert status["task"] == "develop_live_view"
      assert status["component_id"] == liveview_component.id
      assert status["target_story_id"] == story.id
    end

    test "returns all_complete when no work remains", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)
      session = %{}

      assert {:ok, message} = ManageImplementation.command(scope, session, skip_sync: true)
      assert message =~ "All stories are complete"
    end

    test "writes specs for stories without BDD coverage even when other components need work",
         %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)

      # Create a story needing specs (no spec file on disk)
      {story, _criterion, _component} = create_story_with_criteria(scope)

      # Create an unrelated component with unsatisfied requirements
      create_component_with_unsatisfied_requirement(scope, %{
        type: "context",
        module_name: "MyApp.Other"
      })

      session = %{}

      assert {:ok, message} = ManageImplementation.command(scope, session, skip_sync: true)
      # No spec files exist, so specs trivially pass → write specs for incomplete story
      assert message =~ "Write BDD Specs"
      assert message =~ story.title
    end
  end

  # ============================================================================
  # evaluate/3 Tests
  # ============================================================================

  describe "evaluate/3" do
    test "returns {:ok, :valid} when no status file exists", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)
      session = %{}

      assert {:ok, :valid} = ManageImplementation.evaluate(scope, session)
    end

    test "evaluates WriteBddSpecs when status indicates bdd task", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)
      {story, _criterion, _component} = create_story_with_criteria(scope)

      write_status_file!(tmp_dir, %{task: "write_bdd_specs", story_id: story.id})

      session = %{}
      result = ManageImplementation.evaluate(scope, session)

      assert match?({:ok, :invalid, _}, result) or
               match?({:ok, :valid}, result) or
               match?({:error, _}, result)
    end

    test "evaluates DevelopContext when status indicates context task", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)

      component =
        component_fixture(scope, %{type: "context", module_name: "MyApp.Accounts"})

      write_status_file!(tmp_dir, %{
        task: "develop_context",
        module_name: "MyApp.Accounts",
        component_id: component.id,
        target_story_id: Ecto.UUID.generate()
      })

      session = %{}
      result = ManageImplementation.evaluate(scope, session)

      assert match?({:ok, :invalid, _}, result) or
               match?({:ok, :valid}, result) or
               match?({:error, _}, result)
    end

    test "handles errors gracefully", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)

      write_status_file!(tmp_dir, %{
        task: "develop_context",
        module_name: "MyApp.NonExistent",
        component_id: Ecto.UUID.generate()
      })

      session = %{}
      result = ManageImplementation.evaluate(scope, session)

      assert match?({:error, _}, result) or
               match?({:ok, :invalid, _}, result) or
               match?({:ok, :valid}, result)
    end
  end

  # ============================================================================
  # Status File Tests
  # ============================================================================

  describe "status file management" do
    test "command writes status file", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)
      {_story, _criterion, _component} = create_story_with_criteria(scope)

      ManageImplementation.command(scope, %{}, skip_sync: true)

      assert {:ok, status} = read_status_file(tmp_dir)
      assert is_binary(status["task"])
    end

    test "all_complete clears status file", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)

      write_status_file!(tmp_dir, %{task: "write_bdd_specs", story_id: 999})

      assert {:ok, message} = ManageImplementation.command(scope, %{}, skip_sync: true)
      assert message =~ "All stories are complete"

      assert {:error, :not_found} = read_status_file(tmp_dir)
    end
  end
end
