defmodule CodeMySpec.AgentTasks.ComponentCodeTest do
  @moduledoc false
  use CodeMySpec.DataCase

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

  defp create_session(context, _opts \\ []) do
    %{project: project, component: component} = context

    session = %{
      project: project,
      component: component
    }

    Map.put(context, :session, session)
  end

  # ============================================================================
  # evaluate/3 Tests
  # ============================================================================

  describe "evaluate/3" do
    setup [:create_scope, :create_project, :create_component, :create_session]

    test "returns invalid when implementation_file requirement is unsatisfied", %{
      session: session,
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

      assert {:ok, :invalid, feedback} = ComponentCode.evaluate(scope, session)
      assert feedback =~ "requirements not met"
    end

    test "returns invalid when tests_passing requirement is unsatisfied", %{
      session: session,
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

      assert {:ok, :invalid, feedback} = ComponentCode.evaluate(scope, session)
      assert feedback =~ "requirements not met"
    end

    test "returns valid when all :code requirements are satisfied", %{
      session: session,
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
        satisfied: true
      })

      assert {:ok, :valid} = ComponentCode.evaluate(scope, session)
    end

    test "ignores non-code artifact type requirements", %{
      session: session,
      scope: scope,
      component: component
    } do
      # Satisfied code requirements
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
        satisfied: true
      })

      # Unsatisfied non-code requirement — should be ignored
      requirement_fixture(scope, component, %{
        name: "test_file",
        artifact_type: :tests,
        description: "Component test file exists",
        satisfied: false
      })

      assert {:ok, :valid} = ComponentCode.evaluate(scope, session)
    end
  end
end
