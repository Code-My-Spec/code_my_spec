defmodule CodeMySpec.AgentTasks.FixBddSpecsTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.AgentTasks.FixBddSpecs
  alias CodeMySpec.Environments.Environment

  import CodeMySpec.UsersFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.AcceptanceCriteriaFixtures
  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.ProblemsFixtures
  import CodeMySpec.RequirementsFixtures

  @moduletag :tmp_dir

  # ============================================================================
  # Test Helpers
  # ============================================================================

  defp scope_with_env(tmp_dir) do
    scope = full_scope_fixture()
    %{scope | environment: Environment.new(:local, tmp_dir)}
  end

  defp task do
    %{}
  end

  defp create_implemented_component(scope, module_name \\ "MyAppWeb.UserLive") do
    component = component_fixture(scope, %{type: "liveview", module_name: module_name})

    # Add a satisfied implementation_file requirement
    requirement_fixture(scope, component, %{
      name: "implementation_file",
      artifact_type: :code,
      description: "Implementation file exists",
      satisfied: true
    })

    # Reload component with requirements
    CodeMySpec.Components.get_component(scope, component.id)
  end

  defp create_unimplemented_component(scope, module_name \\ "MyAppWeb.PendingLive") do
    component = component_fixture(scope, %{type: "liveview", module_name: module_name})

    # Add an unsatisfied implementation_file requirement
    requirement_fixture(scope, component, %{
      name: "implementation_file",
      artifact_type: :code,
      description: "Implementation file exists",
      satisfied: false
    })

    component
  end

  defp create_story_with_component(scope, component, title \\ "Test Story") do
    story = story_fixture(scope, %{title: title, component_id: component.id})
    criterion = criterion_fixture(scope, story, %{description: "Test criterion"})
    %{story | criteria: [criterion]}
  end

  defp spex_file_path(story) do
    # Match the convention used by Parser.derive_story_id
    "test/spex/#{story.id}_test_story/criterion_1_test_criterion_spex.exs"
  end

  defp create_spex_problem(scope, story) do
    problem_fixture(scope, %{
      source: "spex",
      source_type: :test,
      file_path: spex_file_path(story),
      message: "Expected user to see welcome message",
      severity: :error,
      category: "spex"
    })
  end

  # ============================================================================
  # command/2 Tests
  # ============================================================================

  describe "command/2" do
    test "returns all-passing message when no spex problems exist", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)

      assert {:ok, prompt} = FixBddSpecs.command(scope, task())
      assert prompt =~ "All BDD specs are passing"
    end

    test "returns unimplemented message when all failures are for unimplemented components", %{
      tmp_dir: tmp_dir
    } do
      scope = scope_with_env(tmp_dir)
      component = create_unimplemented_component(scope)
      story = create_story_with_component(scope, component)
      create_spex_problem(scope, story)

      assert {:ok, prompt} = FixBddSpecs.command(scope, task())
      assert prompt =~ "not yet been implemented"
    end

    test "builds fix prompt with failure details for implemented components", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)
      component = create_implemented_component(scope)
      story = create_story_with_component(scope, component)
      create_spex_problem(scope, story)

      assert {:ok, prompt} = FixBddSpecs.command(scope, task())
      assert prompt =~ "Fix BDD Specs"
      assert prompt =~ "failing"
      assert prompt =~ story.title
      assert prompt =~ "Expected user to see welcome message"
    end

    test "includes component module name in prompt", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)
      component = create_implemented_component(scope, "MyAppWeb.DashboardLive")
      story = create_story_with_component(scope, component)
      create_spex_problem(scope, story)

      assert {:ok, prompt} = FixBddSpecs.command(scope, task())
      assert prompt =~ "MyAppWeb.DashboardLive"
    end

    test "filters out problems with no derivable story_id", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)

      # Problem with a file path that doesn't match story_id convention
      problem_fixture(scope, %{
        source: "spex",
        source_type: :test,
        file_path: "test/spex/random_spec.exs",
        message: "Some failure",
        severity: :error,
        category: "spex"
      })

      assert {:ok, prompt} = FixBddSpecs.command(scope, task())
      assert prompt =~ "All BDD specs are passing" or prompt =~ "not yet been implemented"
    end
  end

  # ============================================================================
  # evaluate/2 Tests
  # ============================================================================

  describe "evaluate/2" do
    test "returns {:ok, :valid} when no spex problems exist", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)

      assert {:ok, :valid} = FixBddSpecs.evaluate(scope, task())
    end

    test "returns {:ok, :valid} when all failures are for unimplemented components", %{
      tmp_dir: tmp_dir
    } do
      scope = scope_with_env(tmp_dir)
      component = create_unimplemented_component(scope)
      story = create_story_with_component(scope, component)
      create_spex_problem(scope, story)

      assert {:ok, :valid} = FixBddSpecs.evaluate(scope, task())
    end

    test "returns {:ok, :invalid, feedback} when relevant failures remain", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)
      component = create_implemented_component(scope)
      story = create_story_with_component(scope, component)
      create_spex_problem(scope, story)

      assert {:ok, :invalid, feedback} = FixBddSpecs.evaluate(scope, task())
      assert feedback =~ "BDD spec failure"
      assert feedback =~ story.title
      assert feedback =~ "Expected user to see welcome message"
    end

    test "feedback includes count of remaining failures", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)
      component = create_implemented_component(scope)
      story = create_story_with_component(scope, component)

      # Create multiple problems
      create_spex_problem(scope, story)

      problem_fixture(scope, %{
        source: "spex",
        source_type: :test,
        file_path: spex_file_path(story),
        message: "Second failure",
        severity: :error,
        category: "spex",
        line: 2
      })

      assert {:ok, :invalid, feedback} = FixBddSpecs.evaluate(scope, task())
      assert feedback =~ "2 BDD spec failure(s)"
    end
  end
end
