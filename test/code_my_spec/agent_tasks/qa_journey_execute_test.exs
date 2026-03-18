defmodule CodeMySpec.AgentTasks.QaJourneyExecuteTest do
  @moduledoc false
  use CodeMySpecTest.DataCase

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.QaJourneyExecute
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

  defp write_journey_result(env, content \\ nil) do
    write_file!(
      env,
      ".code_my_spec/qa/journey_result.md",
      content ||
        """
        # QA Journey Result

        ## Status

        pass

        ## Journey Results

        ### Happy Path Registration
        - **Result:** pass
        - **Steps taken:** Visited homepage, registered, saw dashboard
        - **Observations:** All steps completed successfully
        """
    )
  end

  # ============================================================================
  # command/3 Tests
  # ============================================================================

  describe "command/3" do
    setup [:create_scope, :create_session]

    test "returns ok tuple with non-empty prompt", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaJourneyExecute.command(scope, session)
      assert is_binary(prompt)
      assert String.length(prompt) > 0
    end

    test "includes document spec projection", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaJourneyExecute.command(scope, session)
      assert prompt =~ "Required Sections"
      assert prompt =~ "Status"
      assert prompt =~ "Journey Results"
    end

    test "includes journey result output path", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaJourneyExecute.command(scope, session)
      assert prompt =~ ".code_my_spec/qa/journey_result.md"
    end

    test "includes journey plan content when it exists", %{scope: scope, session: session} do
      write_file!(scope.environment, ".code_my_spec/qa/journey_plan.md", """
      # Journey Plan

      ## Journeys

      ### Registration Flow
      Steps to test registration.

      ## Prerequisites

      Run seeds first.
      """)

      assert {:ok, prompt} = QaJourneyExecute.command(scope, session)
      assert prompt =~ "Registration Flow"
    end

    test "handles missing journey plan gracefully", %{scope: scope, session: session} do
      assert {:ok, prompt} = QaJourneyExecute.command(scope, session)
      assert prompt =~ "No journey plan found"
    end
  end

  # ============================================================================
  # evaluate/3 Tests
  # ============================================================================

  describe "evaluate/3" do
    setup [:create_scope, :create_session]

    test "returns {:ok, :valid} when result has all required sections", %{
      scope: scope,
      session: session
    } do
      write_journey_result(scope.environment)

      assert {:ok, :valid} = QaJourneyExecute.evaluate(scope, session)
    end

    test "returns {:ok, :invalid, feedback} when result doesn't exist", %{
      scope: scope,
      session: session
    } do
      assert {:ok, :invalid, feedback} = QaJourneyExecute.evaluate(scope, session)
      assert feedback =~ "Journey result not found"
      assert feedback =~ ".code_my_spec/qa/journey_result.md"
    end

    test "returns {:ok, :invalid, feedback} when result is missing required sections", %{
      scope: scope,
      session: session
    } do
      write_journey_result(scope.environment, """
      # QA Journey Result

      ## Status

      pass
      """)

      assert {:ok, :invalid, feedback} = QaJourneyExecute.evaluate(scope, session)
      assert feedback =~ "missing required section"
      assert feedback =~ "Journey Results"
    end
  end
end
