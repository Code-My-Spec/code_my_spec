defmodule CodeMySpec.AgentTasks.QaJourneyTest do
  @moduledoc false
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.QaJourney
  alias CodeMySpec.Environments
  alias CodeMySpec.Support.InMemoryEnvironment

  # ============================================================================
  # Test Helpers
  # ============================================================================

  defp create_scope(_context) do
    {:ok, env} = InMemoryEnvironment.create()
    on_exit(fn -> InMemoryEnvironment.destroy(env) end)

    scope = full_scope_fixture()
    scope = %{scope | environment: env}
    %{scope: scope, tmp_dir: env.cwd}
  end

  defp create_task(context) do
    task = %{project_id: context.scope.active_project.id, component_id: nil, story_id: nil}
    Map.put(context, :task, task)
  end

  # Through the environment the code under test reads from. Writing to disk here
  # would be seeding a filesystem `QaJourney` never looks at.
  defp write_file!(env, relative_path, content) do
    :ok = Environments.write_file(env, relative_path, content)
  end

  # ============================================================================
  # command/2 Tests
  # ============================================================================

  describe "command/2" do
    setup [:create_scope, :create_task]

    test "returns ok tuple with non-empty prompt", %{scope: scope, task: task} do
      assert {:ok, prompt} = QaJourney.command(scope, task)
      assert is_binary(prompt)
      assert String.length(prompt) > 0
    end

    test "includes all three phases", %{scope: scope, task: task} do
      assert {:ok, prompt} = QaJourney.command(scope, task)
      assert prompt =~ "Phase 1: Journey Planning"
      assert prompt =~ "Phase 2: Journey Execution"
      assert prompt =~ "Phase 3: Wallaby Test Generation"
    end

    test "includes journey plan and result output paths", %{scope: scope, task: task} do
      assert {:ok, prompt} = QaJourney.command(scope, task)
      assert prompt =~ ".code_my_spec/qa/journey_plan.md"
      assert prompt =~ ".code_my_spec/qa/journey_result.md"
      assert prompt =~ "test/journeys/"
    end

    test "marks phase 1 as SKIP when journey plan exists", %{scope: scope, task: task} do
      write_file!(scope.environment, ".code_my_spec/qa/journey_plan.md", """
      # Journey Plan
      ## Journeys
      ### Registration Flow
      ## Prerequisites
      Run seeds.
      """)

      assert {:ok, prompt} = QaJourney.command(scope, task)
      assert prompt =~ "Phase 1: Journey Planning — SKIP"
    end

    test "marks phase 2 as SKIP when journey result exists", %{scope: scope, task: task} do
      write_file!(scope.environment, ".code_my_spec/qa/journey_result.md", """
      # Journey Result
      ## Status
      pass
      ## Journey Results
      ### Registration Flow
      """)

      assert {:ok, prompt} = QaJourney.command(scope, task)
      assert prompt =~ "Phase 2: Journey Execution — SKIP"
    end

    test "references QA plan path when it exists", %{scope: scope, task: task} do
      write_file!(scope.environment, ".code_my_spec/qa/plan.md", """
      # QA Plan
      ## App Overview
      Phoenix app on port 4000.
      """)

      assert {:ok, prompt} = QaJourney.command(scope, task)
      assert prompt =~ ".code_my_spec/qa/plan.md"
    end

    test "notes missing context when no QA plan or architecture", %{scope: scope, task: task} do
      assert {:ok, prompt} = QaJourney.command(scope, task)
      assert prompt =~ "No QA plan or architecture"
    end

    test "references architecture path when it exists", %{scope: scope, task: task} do
      write_file!(scope.environment, ".code_my_spec/architecture/overview.md", """
      # Architecture Overview
      Component graph here.
      """)

      assert {:ok, prompt} = QaJourney.command(scope, task)
      assert prompt =~ ".code_my_spec/architecture/overview.md"
    end

    test "notes existing wallaby tests when present", %{scope: scope, task: task} do
      write_file!(scope.environment, "test/journeys/registration_test.exs", """
      defmodule MyAppWeb.Journeys.RegistrationTest do
        use MyAppWeb.FeatureCase, async: false
      end
      """)

      assert {:ok, prompt} = QaJourney.command(scope, task)
      assert prompt =~ "registration_test.exs"
    end
  end
end
