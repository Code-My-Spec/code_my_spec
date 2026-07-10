defmodule CodeMySpec.AgentTasks.ComponentCodeTest do
  @moduledoc false
  use CodeMySpecTest.DataCase

  import CodeMySpec.UsersFixtures
  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.RequirementsFixtures

  alias CodeMySpec.AgentTasks.ComponentCode
  alias CodeMySpec.Environments.Environment

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
    project = scope.active_project
    Map.put(context, :project, project)
  end

  defp create_component(context, attrs \\ %{}) do
    %{project: project, scope: scope} = context

    default_attrs = %{
      name: "TestModule",
      description: "A test module",
      type: "module",
      module_name: "TestApp.TestModule",
      project_id: project.id
    }

    component = component_fixture(scope, Map.merge(default_attrs, attrs))
    Map.put(context, :component, component)
  end

  defp create_task(context, _opts \\ []) do
    %{scope: scope, component: component} = context

    task = %{
      component_id: component.id,
      project_id: scope.active_project.id,
      story_id: nil
    }

    Map.put(context, :task, task)
  end

  # ============================================================================
  # evaluate/3 Tests
  # ============================================================================

  describe "evaluate/3" do
    setup [:create_scope, :create_project, :create_component, :create_task]

    test "returns invalid when implementation_file requirement is unsatisfied", %{
      task: task,
      scope: scope,
      component: component
    } do
      requirement_fixture(scope, component, %{
        name: "implementation_file",
        artifact_type: :code,
        description: "Component implementation file exists",
        satisfied: false,
        details: %{reason: "File missing", path: "lib/test_app/test_module.ex"}
      })

      assert {:ok, :invalid, feedback} = ComponentCode.evaluate(scope, task)
      assert feedback =~ "requirements not met"
    end

    test "returns invalid when tests_passing requirement is unsatisfied", %{
      task: task,
      scope: scope,
      component: component
    } do
      requirement_fixture(scope, component, %{
        name: "implementation_file",
        artifact_type: :code,
        description: "Component implementation file exists",
        satisfied: true
      })

      requirement_fixture(scope, component, %{
        name: "tests_passing",
        artifact_type: :code,
        description: "Component tests are passing",
        satisfied: false,
        details: %{reason: "Test failures found", problem_count: 2}
      })

      assert {:ok, :invalid, feedback} = ComponentCode.evaluate(scope, task)
      assert feedback =~ "requirements not met"
    end

    test "returns valid when all :code requirements are satisfied", %{
      task: task,
      scope: scope,
      component: component
    } do
      satisfy_code_requirements(scope, component)

      assert {:ok, :valid} = ComponentCode.evaluate(scope, task)
    end

    test "ignores non-code artifact type requirements", %{
      task: task,
      scope: scope,
      component: component
    } do
      # Seeding :implementation and :test Files satisfies both :code requirements.
      # evaluate only inspects :code artifacts, so spec/test-artifact requirements
      # are irrelevant.
      satisfy_code_requirements(scope, component)

      assert {:ok, :valid} = ComponentCode.evaluate(scope, task)
    end

    test "returns invalid when problems exist on code file even if requirements pass", %{
      task: task,
      scope: scope,
      component: component,
      project: project
    } do
      satisfy_code_requirements(scope, component)
      %{code_file: code_file} = CodeMySpec.Utils.component_files(component, project)

      {:ok, _} =
        CodeMySpec.Problems.create_problems(scope, [
          %{
            severity: :warning,
            source_type: :static_analysis,
            source: "credo",
            file_path: code_file,
            message: "Modules should have a @moduledoc tag",
            category: "readability"
          }
        ])

      assert {:ok, :invalid, feedback} = ComponentCode.evaluate(scope, task)
      assert feedback =~ "@moduledoc"
    end

    test "returns invalid when problems exist on test file even if requirements pass", %{
      task: task,
      scope: scope,
      component: component,
      project: project
    } do
      satisfy_code_requirements(scope, component)
      %{test_file: test_file} = CodeMySpec.Utils.component_files(component, project)

      {:ok, _} =
        CodeMySpec.Problems.create_problems(scope, [
          %{
            severity: :error,
            source_type: :test,
            source: "exunit",
            file_path: test_file,
            message: "test failed: expected true, got false",
            category: "test_failure"
          }
        ])

      assert {:ok, :invalid, feedback} = ComponentCode.evaluate(scope, task)
      assert feedback =~ "test failed"
    end

    test "combines requirement and problem feedback when both fail", %{
      task: task,
      scope: scope,
      component: component,
      project: project
    } do
      requirement_fixture(scope, component, %{
        name: "implementation_file",
        artifact_type: :code,
        description: "Component implementation file exists",
        satisfied: false,
        details: %{reason: "File missing"}
      })

      %{code_file: code_file} = CodeMySpec.Utils.component_files(component, project)

      {:ok, _} =
        CodeMySpec.Problems.create_problems(scope, [
          %{
            severity: :error,
            source_type: :static_analysis,
            source: "compiler",
            file_path: code_file,
            message: "undefined function foo/0",
            category: "undefined_function"
          }
        ])

      assert {:ok, :invalid, feedback} = ComponentCode.evaluate(scope, task)
      assert feedback =~ "requirements not met"
      assert feedback =~ "undefined function"
    end
  end

  # ============================================================================
  # dispatch/1 — returns the work description; sub-agent role + start_task args
  # are appended by the RequirementsMapper based on execution_type. The old
  # {:ok, prompt} / {:error, :invalid_node} defensive contract was retired
  # along with the in-body dispatch-directive convention.
  # ============================================================================

  describe "dispatch/1" do
    test "returns a non-empty work description for any graph node" do
      node = %{
        name: "implementation_file",
        entity_type: "component",
        entity_id: "abc",
        entity_name: "Foo"
      }

      result = ComponentCode.dispatch(node)
      assert is_binary(result)
      assert result =~ "Use when"
    end
  end

  defp satisfy_code_requirements(scope, component) do
    project = scope.active_project
    %{code_file: code_path, test_file: test_path} =
      CodeMySpec.Utils.component_files(component, project)

    %CodeMySpec.Files.File{}
    |> CodeMySpec.Files.File.changeset(%{
      path: code_path,
      role: :implementation,
      project_id: project.id,
      component_id: component.id,
      valid: true
    })
    |> CodeMySpec.Repo.insert!()

    %CodeMySpec.Files.File{}
    |> CodeMySpec.Files.File.changeset(%{
      path: test_path,
      role: :test,
      project_id: project.id,
      component_id: component.id,
      valid: true
    })
    |> CodeMySpec.Repo.insert!()

    # tests_passing also needs a fresh analysis run — zero persisted problems
    # only counts once exunit results are current for these files.
    CodeMySpec.AnalysisFixtures.fresh_analysis_runs_fixture(scope, ["exunit"])
  end
end
