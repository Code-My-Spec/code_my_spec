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

  defp create_session(context) do
    session = %{project: context.scope.active_project}
    Map.put(context, :session, session)
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
  # command/3 Tests
  # ============================================================================

  describe "command/3" do
    setup [:create_scope, :create_session]

    test "returns ok tuple with non-empty prompt", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaJourneyPlan.command(scope, session)
      assert is_binary(prompt)
      assert String.length(prompt) > 0
    end

    test "includes document spec projection", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaJourneyPlan.command(scope, session)
      assert prompt =~ "Required Sections"
      assert prompt =~ "Journeys"
      assert prompt =~ "Prerequisites"
    end

    test "includes journey plan output path", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaJourneyPlan.command(scope, session)
      assert prompt =~ ".code_my_spec/qa/journey_plan.md"
    end

    test "references QA plan path when it exists", %{scope: scope, session: session} do
      write_file!(scope.environment, ".code_my_spec/qa/plan.md", """
      # QA Plan

      ## App Overview
      Phoenix app on port 4000.
      """)

      assert {:ok, prompt} = QaJourneyPlan.command(scope, session)
      assert prompt =~ ".code_my_spec/qa/plan.md"
    end

    test "notes missing context when no QA plan or architecture", %{
      scope: scope,
      session: session
    } do
      assert {:ok, prompt} = QaJourneyPlan.command(scope, session)
      assert prompt =~ "No QA plan or architecture"
    end

    test "references architecture path when it exists", %{scope: scope, session: session} do
      write_file!(scope.environment, ".code_my_spec/architecture/overview.md", """
      # Architecture Overview
      Component graph here.
      """)

      assert {:ok, prompt} = QaJourneyPlan.command(scope, session)
      assert prompt =~ ".code_my_spec/architecture/overview.md"
    end
  end

  # ============================================================================
  # evaluate/3 Tests
  # ============================================================================

  describe "evaluate/3" do
    setup [:create_scope, :create_session]

    test "returns {:ok, :valid} when plan has all required sections", %{
      scope: scope,
      session: session
    } do
      write_journey_plan(scope.environment)

      assert {:ok, :valid} = QaJourneyPlan.evaluate(scope, session)
    end

    test "returns {:ok, :invalid, feedback} when plan doesn't exist", %{
      scope: scope,
      session: session
    } do
      assert {:ok, :invalid, feedback} = QaJourneyPlan.evaluate(scope, session)
      assert feedback =~ "Journey plan not found"
      assert feedback =~ ".code_my_spec/qa/journey_plan.md"
    end

    test "returns {:ok, :invalid, feedback} when plan is missing required sections", %{
      scope: scope,
      session: session
    } do
      write_journey_plan(scope.environment, """
      # QA Journey Plan

      ## Journeys

      Some journey content.
      """)

      assert {:ok, :invalid, feedback} = QaJourneyPlan.evaluate(scope, session)
      assert feedback =~ "missing required section"
      assert feedback =~ "Prerequisites"
    end
  end
end
