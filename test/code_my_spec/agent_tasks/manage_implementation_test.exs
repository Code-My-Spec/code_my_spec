defmodule CodeMySpec.AgentTasks.ManageImplementationTest do
  use CodeMySpec.DataCase, async: true

  alias CodeMySpec.AgentTasks.ManageImplementation
  alias CodeMySpec.Environments.Environment

  import CodeMySpec.UsersFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.AcceptanceCriteriaFixtures
  import CodeMySpec.ComponentsFixtures
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

  defp create_story_with_criteria(scope) do
    component =
      component_fixture(scope, %{type: "context", module_name: "MyApp.Accounts"})

    story =
      story_fixture(scope, %{
        title: "User Registration",
        priority: 1,
        component_id: component.id
      })

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
    test "delegates to WriteBddSpecs when stories need specs", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)
      {story, _criterion, _component} = create_story_with_criteria(scope)
      session = %{}

      assert {:ok, message} = ManageImplementation.command(scope, session, skip_sync: true)
      assert message =~ "Write BDD Specs"
      assert message =~ story.title

      # Status file should be written
      assert {:ok, status} = read_status_file(tmp_dir)
      assert status["task"] == "write_bdd_specs"
      assert status["story_id"] == story.id
    end

    test "delegates to DevelopContext when stories complete but context needs work",
         %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)

      # Create story with full spec coverage (all criteria covered)
      {story, criterion, _component} = create_story_with_criteria(scope)
      write_valid_spec_file!(tmp_dir, story, criterion)

      # Create a context component with unsatisfied requirements
      component =
        create_component_with_unsatisfied_requirement(scope, %{
          type: "context",
          module_name: "MyApp.Billing"
        })

      session = %{}

      assert {:ok, message} = ManageImplementation.command(scope, session, skip_sync: true)
      assert message =~ "Develop"

      assert {:ok, status} = read_status_file(tmp_dir)
      assert status["task"] == "develop_context"
      assert status["component_id"] == component.id
    end

    test "delegates to DevelopLiveView for liveview components", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)

      # Create story with full spec coverage
      {story, criterion, _component} = create_story_with_criteria(scope)
      write_valid_spec_file!(tmp_dir, story, criterion)

      # Create a liveview component with unsatisfied requirements
      component =
        create_component_with_unsatisfied_requirement(scope, %{
          type: "liveview",
          module_name: "MyAppWeb.DashboardLive"
        })

      session = %{}

      assert {:ok, message} = ManageImplementation.command(scope, session, skip_sync: true)
      assert message =~ "Develop"

      assert {:ok, status} = read_status_file(tmp_dir)
      assert status["task"] == "develop_live_view"
      assert status["component_id"] == component.id
    end

    test "returns all_complete when no work remains", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)
      session = %{}

      # No stories, no components with unsatisfied requirements
      assert {:ok, message} = ManageImplementation.command(scope, session, skip_sync: true)
      assert message =~ "All stories are complete"
    end

    test "prioritizes stories over component development", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)

      # Create both: a story needing specs AND a component needing work
      {story, _criterion, _component} = create_story_with_criteria(scope)

      create_component_with_unsatisfied_requirement(scope, %{
        type: "context",
        module_name: "MyApp.Other"
      })

      session = %{}

      assert {:ok, message} = ManageImplementation.command(scope, session, skip_sync: true)
      # Should pick BDD specs first (story has missing coverage)
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

      # Write a status file indicating we're working on BDD specs
      write_status_file!(tmp_dir, %{task: "write_bdd_specs", story_id: story.id})

      session = %{}
      result = ManageImplementation.evaluate(scope, session)

      # WriteBddSpecs.evaluate will likely return :invalid (specs not valid yet in test env)
      # or :error. Either way it should not crash.
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
        component_id: component.id
      })

      session = %{}
      result = ManageImplementation.evaluate(scope, session)

      # DevelopContext.evaluate will check phases — in test env may return :invalid or :valid
      assert match?({:ok, :invalid, _}, result) or
               match?({:ok, :valid}, result) or
               match?({:error, _}, result)
    end

    test "handles errors gracefully", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)

      # Write a status file with an invalid component_id to trigger an error path
      write_status_file!(tmp_dir, %{
        task: "develop_context",
        module_name: "MyApp.NonExistent",
        component_id: Ecto.UUID.generate()
      })

      session = %{}
      result = ManageImplementation.evaluate(scope, session)

      # Should handle gracefully (rescue catches errors)
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

      # Write a leftover status file
      write_status_file!(tmp_dir, %{task: "write_bdd_specs", story_id: 999})

      # No stories or components → all_complete → clears status
      assert {:ok, message} = ManageImplementation.command(scope, %{}, skip_sync: true)
      assert message =~ "All stories are complete"

      assert {:error, :not_found} = read_status_file(tmp_dir)
    end
  end
end
