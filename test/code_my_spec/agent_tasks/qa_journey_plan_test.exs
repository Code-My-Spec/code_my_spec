defmodule CodeMySpec.AgentTasks.QaJourneyPlanTest do
  @moduledoc false
  use CodeMySpecTest.DataCase

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.QaJourneyPlan
  alias CodeMySpec.Environments.Environment

  # ============================================================================
  # Test Helpers
  # ============================================================================

  defp create_scope(_context) do
    {:ok, tmp_dir} = Briefly.create(directory: true)
    scope = full_scope_fixture()
    scope = %{scope | environment: Environment.new(:local, tmp_dir)}
    %{scope: scope, tmp_dir: tmp_dir}
  end

  defp create_task(context) do
    task = %{project_id: context.scope.active_project.id, component_id: nil, story_id: nil}
    Map.put(context, :task, task)
  end

  defp write_file!(env, relative_path, content) do
    full_path = Path.join(env.cwd, relative_path)
    full_path |> Path.dirname() |> File.mkdir_p!()
    File.write!(full_path, content)
  end

  defp write_journey_plan(env, content \\ nil) do
    write_file!(
      env,
      ".code_my_spec/qa/journey_plan.md",
      content ||
        """
        # QA Journey Plan

        ## Journeys

        ### Happy Path Registration
        - **Role:** New user
        - **Steps:**
          1. Visit homepage
          2. Click register
          3. Fill in form
          4. Submit
        - **Expected outcome:** User is logged in and sees dashboard

        ## Prerequisites

        - Start server: `mix phx.server`
        - Run seeds: `mix run priv/repo/qa_seeds.exs`
        """
    )
  end

  # ============================================================================
  # command/2 Tests
  # ============================================================================

  describe "command/2" do
    setup [:create_scope, :create_task]

    test "returns ok tuple with non-empty prompt", %{scope: scope, task: task} do
      assert {:ok, prompt} = QaJourneyPlan.command(scope, task)
      assert is_binary(prompt)
      assert String.length(prompt) > 0
    end

    test "includes document spec projection", %{scope: scope, task: task} do
      assert {:ok, prompt} = QaJourneyPlan.command(scope, task)
      assert prompt =~ "Required Sections"
      assert prompt =~ "Journeys"
      assert prompt =~ "Prerequisites"
    end

    test "includes journey plan output path", %{scope: scope, task: task} do
      assert {:ok, prompt} = QaJourneyPlan.command(scope, task)
      assert prompt =~ ".code_my_spec/qa/journey_plan.md"
    end

    test "references QA plan path when it exists", %{scope: scope, task: task} do
      write_file!(scope.environment, ".code_my_spec/qa/plan.md", """
      # QA Plan

      ## App Overview
      Phoenix app on port 4000.
      """)

      assert {:ok, prompt} = QaJourneyPlan.command(scope, task)
      assert prompt =~ ".code_my_spec/qa/plan.md"
    end

    test "notes missing context when no QA plan or architecture", %{
      scope: scope,
      task: task
    } do
      assert {:ok, prompt} = QaJourneyPlan.command(scope, task)
      assert prompt =~ "No QA plan or architecture"
    end

    test "references architecture path when it exists", %{scope: scope, task: task} do
      write_file!(scope.environment, ".code_my_spec/architecture/overview.md", """
      # Architecture Overview
      Component graph here.
      """)

      assert {:ok, prompt} = QaJourneyPlan.command(scope, task)
      assert prompt =~ ".code_my_spec/architecture/overview.md"
    end
  end

  # ============================================================================
  # evaluate/2 Tests
  # ============================================================================

  describe "evaluate/2" do
    setup [:create_scope, :create_task]

    test "returns {:ok, :valid} when plan has all required sections", %{
      scope: scope,
      task: task
    } do
      write_journey_plan(scope.environment)

      assert {:ok, :valid} = QaJourneyPlan.evaluate(scope, task)
    end

    test "returns {:ok, :invalid, feedback} when plan doesn't exist", %{
      scope: scope,
      task: task
    } do
      assert {:ok, :invalid, feedback} = QaJourneyPlan.evaluate(scope, task)
      assert feedback =~ "Journey plan not found"
      assert feedback =~ ".code_my_spec/qa/journey_plan.md"
    end

    test "returns {:ok, :invalid, feedback} when plan is missing required sections", %{
      scope: scope,
      task: task
    } do
      write_journey_plan(scope.environment, """
      # QA Journey Plan

      ## Journeys

      Some journey content.
      """)

      assert {:ok, :invalid, feedback} = QaJourneyPlan.evaluate(scope, task)
      assert feedback =~ "missing required section"
      assert feedback =~ "Prerequisites"
    end
  end
end
