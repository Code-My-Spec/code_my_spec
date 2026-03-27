defmodule CodeMySpec.AgentTasks.QaJourneyWallabyTest do
  @moduledoc false
  use CodeMySpecTest.DataCase

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.QaJourneyWallaby
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

  defp write_journey_test(env, name \\ "registration") do
    write_file!(env, "test/journeys/#{name}_test.exs", """
    defmodule MyAppWeb.Journeys.#{Macro.camelize(name)}Test do
      use MyAppWeb.FeatureCase, async: false

      feature "#{name} journey", %{session: session} do
        session
        |> visit("/")
        |> assert_has(css("h1"))
      end
    end
    """)
  end

  # ============================================================================
  # command/2 Tests
  # ============================================================================

  describe "command/2" do
    setup [:create_scope, :create_task]

    test "returns ok tuple with non-empty prompt", %{scope: scope, task: task} do
      assert {:ok, prompt} = QaJourneyWallaby.command(scope, task)
      assert is_binary(prompt)
      assert String.length(prompt) > 0
    end

    test "includes Wallaby test output directory", %{scope: scope, task: task} do
      assert {:ok, prompt} = QaJourneyWallaby.command(scope, task)
      assert prompt =~ "test/journeys/"
    end

    test "includes journey plan content when it exists", %{scope: scope, task: task} do
      write_file!(scope.environment, ".code_my_spec/qa/journey_plan.md", """
      # Journey Plan

      ## Journeys

      ### Checkout Flow
      Steps for checkout.

      ## Prerequisites

      Run seeds.
      """)

      assert {:ok, prompt} = QaJourneyWallaby.command(scope, task)
      assert prompt =~ "Checkout Flow"
    end

    test "includes journey result content when it exists", %{scope: scope, task: task} do
      write_file!(scope.environment, ".code_my_spec/qa/journey_result.md", """
      # Journey Result

      ## Status
      pass

      ## Journey Results

      ### Checkout Flow
      - **Result:** pass
      """)

      assert {:ok, prompt} = QaJourneyWallaby.command(scope, task)
      assert prompt =~ "Checkout Flow"
    end

    test "notes existing tests when present", %{scope: scope, task: task} do
      write_journey_test(scope.environment)

      assert {:ok, prompt} = QaJourneyWallaby.command(scope, task)
      assert prompt =~ "registration_test.exs"
    end

    test "handles missing journey plan and result gracefully", %{
      scope: scope,
      task: task
    } do
      assert {:ok, prompt} = QaJourneyWallaby.command(scope, task)
      assert prompt =~ "No journey plan found"
      assert prompt =~ "No journey result found"
    end
  end

  # ============================================================================
  # evaluate/2 Tests
  # ============================================================================

  describe "evaluate/2" do
    setup [:create_scope, :create_task]

    test "returns {:ok, :valid} when at least one journey test exists", %{
      scope: scope,
      task: task
    } do
      write_journey_test(scope.environment)

      assert {:ok, :valid} = QaJourneyWallaby.evaluate(scope, task)
    end

    test "returns {:ok, :valid} with multiple journey tests", %{
      scope: scope,
      task: task
    } do
      write_journey_test(scope.environment, "registration")
      write_journey_test(scope.environment, "checkout")

      assert {:ok, :valid} = QaJourneyWallaby.evaluate(scope, task)
    end

    test "returns {:ok, :invalid, feedback} when no tests exist", %{
      scope: scope,
      task: task
    } do
      assert {:ok, :invalid, feedback} = QaJourneyWallaby.evaluate(scope, task)
      assert feedback =~ "No journey tests found"
      assert feedback =~ "test/journeys/"
    end
  end
end
