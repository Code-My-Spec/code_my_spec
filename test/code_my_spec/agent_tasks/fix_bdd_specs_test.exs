defmodule CodeMySpec.AgentTasks.FixBddSpecsTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.AgentTasks.FixBddSpecs
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Stories

  import CodeMySpec.AnalysisFixtures
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

  defp story_task(story) do
    %{story_id: story.id}
  end

  # The gate needs a File row with role :bdd_spec owned by the story —
  # that is what "the story has specs at all" means to it.
  defp create_bdd_spec_file(scope, story) do
    {_count, _} =
      CodeMySpec.Files.upsert_files(scope, [
        %{
          path: spex_file_path(story),
          role: :bdd_spec,
          story_id: story.id,
          valid: true,
          mtime: DateTime.utc_now()
        }
      ])

    :ok
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
    # Match the convention `Parser.derive_story_number/1` reads: the directory
    # is named from the story's durable number, not its primary key.
    "test/spex/#{story.number}_test_story/criterion_1_test_criterion_spex.exs"
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

  # ============================================================================
  # evaluate/2 — the specs-passing gate
  #
  # `evaluate/2` is scoped to ONE story (the task's entity) and is a latch:
  # it requires a fresh green spex run for that story and, on a pass, sets
  # `specs_ready`. This is deliberately narrower than `command/2`, which
  # still builds a project-wide fix prompt.
  # ============================================================================

  describe "evaluate/2" do
    test "sets specs_ready when the story's specs are green on a fresh run", %{
      tmp_dir: tmp_dir
    } do
      scope = scope_with_env(tmp_dir)
      component = create_implemented_component(scope)
      story = create_story_with_component(scope, component)
      create_bdd_spec_file(scope, story)
      fresh_analysis_runs_fixture(scope, ["spex"])

      refute story.specs_ready == true

      assert {:ok, :valid} = FixBddSpecs.evaluate(scope, story_task(story))

      assert Stories.get_story(scope, story.id).specs_ready == true
    end

    test "reports pending, not failure, when the spex run is stale", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)
      component = create_implemented_component(scope)
      story = create_story_with_component(scope, component)
      create_bdd_spec_file(scope, story)

      # No fresh run stamped — the ledger has nothing current for spex.
      assert {:ok, :invalid, feedback} = FixBddSpecs.evaluate(scope, story_task(story))

      assert feedback =~ "analysis pending"
      refute feedback =~ "BDD spec failure"
      refute Stories.get_story(scope, story.id).specs_ready == true
    end

    test "refuses the flip when the story has no BDD spec files", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)
      component = create_implemented_component(scope)
      story = create_story_with_component(scope, component)
      fresh_analysis_runs_fixture(scope, ["spex"])

      assert {:ok, :invalid, feedback} = FixBddSpecs.evaluate(scope, story_task(story))

      assert feedback =~ "no BDD spec files"
      refute Stories.get_story(scope, story.id).specs_ready == true
    end

    test "returns {:ok, :invalid, feedback} when the story's own specs fail", %{
      tmp_dir: tmp_dir
    } do
      scope = scope_with_env(tmp_dir)
      component = create_implemented_component(scope)
      story = create_story_with_component(scope, component)
      create_bdd_spec_file(scope, story)
      create_spex_problem(scope, story)
      fresh_analysis_runs_fixture(scope, ["spex"])

      assert {:ok, :invalid, feedback} = FixBddSpecs.evaluate(scope, story_task(story))
      assert feedback =~ "BDD spec failure"
      assert feedback =~ story.title
      assert feedback =~ "Expected user to see welcome message"
      refute Stories.get_story(scope, story.id).specs_ready == true
    end

    test "feedback includes count of remaining failures", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)
      component = create_implemented_component(scope)
      story = create_story_with_component(scope, component)
      create_bdd_spec_file(scope, story)

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

      fresh_analysis_runs_fixture(scope, ["spex"])

      assert {:ok, :invalid, feedback} = FixBddSpecs.evaluate(scope, story_task(story))
      assert feedback =~ "2 BDD spec failure(s)"
    end

    test "another story's failing spec does not hold this story short of ready", %{
      tmp_dir: tmp_dir
    } do
      scope = scope_with_env(tmp_dir)
      component = create_implemented_component(scope)

      green_story = create_story_with_component(scope, component, "Green Story")
      create_bdd_spec_file(scope, green_story)

      red_story = create_story_with_component(scope, component, "Red Story")
      create_bdd_spec_file(scope, red_story)
      create_spex_problem(scope, red_story)

      fresh_analysis_runs_fixture(scope, ["spex"])

      assert {:ok, :valid} = FixBddSpecs.evaluate(scope, story_task(green_story))
      assert Stories.get_story(scope, green_story.id).specs_ready == true

      assert {:ok, :invalid, _feedback} = FixBddSpecs.evaluate(scope, story_task(red_story))
      refute Stories.get_story(scope, red_story.id).specs_ready == true
    end

    test "an already-latched story stays valid even with a stale run", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)
      component = create_implemented_component(scope)
      story = create_story_with_component(scope, component)
      create_bdd_spec_file(scope, story)
      {:ok, story} = Stories.set_specs_ready(scope, story, true)

      # No fresh run — freshness gates the flip, never the state.
      assert {:ok, :valid} = FixBddSpecs.evaluate(scope, story_task(story))
      assert Stories.get_story(scope, story.id).specs_ready == true
    end

    test "returns invalid when the task carries no story", %{tmp_dir: tmp_dir} do
      scope = scope_with_env(tmp_dir)

      assert {:ok, :invalid, feedback} = FixBddSpecs.evaluate(scope, task())
      assert feedback =~ "No story found"
    end
  end
end
