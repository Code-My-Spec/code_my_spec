defmodule CodeMySpec.AgentTasks.ProblemFeedbackTest do
  @moduledoc false
  use CodeMySpec.DataCase

  import CodeMySpec.UsersFixtures
  import CodeMySpec.ComponentsFixtures

  alias CodeMySpec.AgentTasks.ProblemFeedback
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Utils

  @moduletag :tmp_dir

  # ============================================================================
  # Test Helpers
  # ============================================================================

  defp create_scope(context) do
    scope = full_scope_fixture()
    scope = %{scope | environment: Environment.new(:local, context.tmp_dir)}
    %{scope: scope}
  end

  defp create_project(context) do
    %{scope: scope} = context
    Map.put(context, :project, scope.active_project)
  end

  defp create_component(context) do
    %{project: project, scope: scope} = context

    component =
      component_fixture(scope, %{
        name: "Accounts",
        description: "Account management",
        type: "context",
        module_name: "TestApp.Accounts",
        project_id: project.id
      })

    Map.put(context, :component, component)
  end

  defp create_problem(scope, attrs) do
    {:ok, _} =
      CodeMySpec.Problems.create_problems(scope, [
        Map.merge(
          %{
            severity: :error,
            source_type: :static_analysis,
            source: "compiler",
            message: "undefined function foo/0",
            category: "undefined_function"
          },
          attrs
        )
      ])
  end

  # ============================================================================
  # for_code_task/3
  # ============================================================================

  describe "for_code_task/3" do
    setup [:create_scope, :create_project, :create_component]

    test "returns nil when no problems exist", %{
      scope: scope,
      component: component,
      project: project
    } do
      assert ProblemFeedback.for_code_task(scope, component, project) == nil
    end

    test "returns formatted feedback when code file has problems", %{
      scope: scope,
      component: component,
      project: project
    } do
      %{code_file: code_file} = Utils.component_files(component, project)

      create_problem(scope, %{
        file_path: code_file,
        message: "undefined function bar/0"
      })

      feedback = ProblemFeedback.for_code_task(scope, component, project)
      assert is_binary(feedback)
      assert feedback =~ "undefined function bar/0"
    end

    test "returns formatted feedback when test file has problems", %{
      scope: scope,
      component: component,
      project: project
    } do
      %{test_file: test_file} = Utils.component_files(component, project)

      create_problem(scope, %{
        file_path: test_file,
        message: "undefined function baz/0"
      })

      feedback = ProblemFeedback.for_code_task(scope, component, project)
      assert is_binary(feedback)
      assert feedback =~ "undefined function baz/0"
    end

    test "includes problems from both code and test files", %{
      scope: scope,
      component: component,
      project: project
    } do
      %{code_file: code_file, test_file: test_file} =
        Utils.component_files(component, project)

      create_problem(scope, %{file_path: code_file, message: "code file error"})
      create_problem(scope, %{file_path: test_file, message: "test file error"})

      feedback = ProblemFeedback.for_code_task(scope, component, project)
      assert feedback =~ "code file error"
      assert feedback =~ "test file error"
    end

    test "includes all problem types", %{
      scope: scope,
      component: component,
      project: project
    } do
      %{code_file: code_file, test_file: test_file} =
        Utils.component_files(component, project)

      # Compiler error on code file
      create_problem(scope, %{
        file_path: code_file,
        source: "compiler",
        source_type: :static_analysis,
        message: "compilation error"
      })

      # Test failure on test file
      create_problem(scope, %{
        file_path: test_file,
        source: "exunit",
        source_type: :test,
        message: "test assertion failed"
      })

      feedback = ProblemFeedback.for_code_task(scope, component, project)
      assert feedback =~ "compilation error"
      assert feedback =~ "test assertion failed"
    end
  end

  # ============================================================================
  # for_test_task/3
  # ============================================================================

  describe "for_test_task/3" do
    setup [:create_scope, :create_project, :create_component]

    test "returns nil when no problems exist", %{
      scope: scope,
      component: component,
      project: project
    } do
      assert ProblemFeedback.for_test_task(scope, component, project) == nil
    end

    test "returns formatted feedback when test file has compilation errors", %{
      scope: scope,
      component: component,
      project: project
    } do
      %{test_file: test_file} = Utils.component_files(component, project)

      create_problem(scope, %{
        file_path: test_file,
        source: "compiler",
        source_type: :static_analysis,
        message: "undefined function live/2"
      })

      feedback = ProblemFeedback.for_test_task(scope, component, project)
      assert is_binary(feedback)
      assert feedback =~ "undefined function live/2"
    end

    test "returns formatted feedback when test file has credo issues", %{
      scope: scope,
      component: component,
      project: project
    } do
      %{test_file: test_file} = Utils.component_files(component, project)

      create_problem(scope, %{
        file_path: test_file,
        source: "credo",
        source_type: :static_analysis,
        severity: :warning,
        message: "Modules should have a @moduledoc tag"
      })

      feedback = ProblemFeedback.for_test_task(scope, component, project)
      assert feedback =~ "@moduledoc"
    end

    test "filters out test failures (source_type == :test)", %{
      scope: scope,
      component: component,
      project: project
    } do
      %{test_file: test_file} = Utils.component_files(component, project)

      create_problem(scope, %{
        file_path: test_file,
        source: "exunit",
        source_type: :test,
        message: "test failed: expected true, got false"
      })

      assert ProblemFeedback.for_test_task(scope, component, project) == nil
    end

    test "returns nil when only test failures exist", %{
      scope: scope,
      component: component,
      project: project
    } do
      %{test_file: test_file} = Utils.component_files(component, project)

      create_problem(scope, %{
        file_path: test_file,
        source: "exunit",
        source_type: :test,
        message: "assertion failed 1"
      })

      create_problem(scope, %{
        file_path: test_file,
        source: "exunit",
        source_type: :test,
        message: "assertion failed 2"
      })

      assert ProblemFeedback.for_test_task(scope, component, project) == nil
    end
  end

  # ============================================================================
  # for_spec_task/3
  # ============================================================================

  describe "for_spec_task/3" do
    setup [:create_scope, :create_project, :create_component]

    test "returns nil when no problems exist", %{
      scope: scope,
      component: component,
      project: project
    } do
      assert ProblemFeedback.for_spec_task(scope, component, project) == nil
    end

    test "returns formatted feedback when spec file has validation problems", %{
      scope: scope,
      component: component,
      project: project
    } do
      %{spec_file: spec_file} = Utils.component_files(component, project)

      create_problem(scope, %{
        file_path: spec_file,
        source: "spec_validation",
        message: "Missing required section: Functions"
      })

      feedback = ProblemFeedback.for_spec_task(scope, component, project)
      assert is_binary(feedback)
      assert feedback =~ "Missing required section"
    end
  end

  # ============================================================================
  # combine/2
  # ============================================================================

  describe "combine/2" do
    test "returns {:ok, :valid} when both inputs are nil" do
      assert {:ok, :valid} = ProblemFeedback.combine(nil, nil)
    end

    test "returns {:ok, :invalid, feedback} with requirement feedback only" do
      assert {:ok, :invalid, "Requirements not met"} =
               ProblemFeedback.combine("Requirements not met", nil)
    end

    test "returns {:ok, :invalid, feedback} with problem feedback only" do
      assert {:ok, :invalid, "Compilation errors found"} =
               ProblemFeedback.combine(nil, "Compilation errors found")
    end

    test "combines both when requirements fail and problems exist" do
      assert {:ok, :invalid, feedback} =
               ProblemFeedback.combine("Requirements not met", "Compilation errors found")

      assert feedback =~ "Requirements not met"
      assert feedback =~ "Compilation errors found"
    end
  end
end
