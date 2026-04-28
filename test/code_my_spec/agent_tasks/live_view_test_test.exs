defmodule CodeMySpec.AgentTasks.LiveViewTestTest do
  @moduledoc false
  use CodeMySpecTest.DataCase

  import CodeMySpec.UsersFixtures
  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.RequirementsFixtures

  alias CodeMySpec.AgentTasks.LiveViewTest
  alias CodeMySpec.Components
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
    Map.put(context, :project, scope.active_project)
  end

  defp create_component(context, attrs \\ %{}) do
    %{project: project, scope: scope} = context

    default_attrs = %{
      name: "DashboardLive",
      description: "Main dashboard page",
      type: "liveview",
      module_name: "TestAppWeb.DashboardLive",
      project_id: project.id
    }

    component = component_fixture(scope, Map.merge(default_attrs, attrs))
    Map.put(context, :component, component)
  end

  defp create_task(context) do
    %{scope: scope, component: component} = context

    Map.put(context, :task, %{
      component_id: component.id,
      project_id: scope.active_project.id,
      story_id: nil
    })
  end

  defp write_code_file(context) do
    %{component: component, project: project, tmp_dir: tmp_dir} = context
    %{code_file: code_file} = CodeMySpec.Utils.component_files(component, project)
    full_path = Path.join(tmp_dir, code_file)
    File.mkdir_p!(Path.dirname(full_path))

    File.write!(full_path, """
    defmodule #{component.module_name} do
      use Phoenix.LiveView

      def mount(_params, _session, socket), do: {:ok, socket}
      def handle_event("refresh", _params, socket), do: {:noreply, socket}
    end
    """)

    context
  end

  defp satisfy_test_requirements(scope, component) do
    requirement_fixture(scope, component, %{
      name: "test_file",
      artifact_type: :tests,
      description: "Component test file exists",
      satisfied: true
    })

    requirement_fixture(scope, component, %{
      name: "test_spec_alignment",
      artifact_type: :tests,
      description: "Test file implements all spec test assertions",
      satisfied: true
    })
  end

  # ============================================================================
  # command/3 Tests
  # ============================================================================

  describe "command/3" do
    setup [:create_scope, :create_project, :create_component, :create_task]

    test "includes project name and description in prompt", %{
      task: task,
      scope: scope,
      project: project
    } do
      assert {:ok, prompt} = LiveViewTest.command(scope, task)
      assert prompt =~ project.name
    end

    test "includes component name, type, and description in prompt", %{
      task: task,
      scope: scope,
      component: component
    } do
      assert {:ok, prompt} = LiveViewTest.command(scope, task)
      assert prompt =~ component.name
      assert prompt =~ component.type
      assert prompt =~ component.description
    end

    test "includes spec file path and test file path in prompt", %{
      task: task,
      scope: scope,
      component: component,
      project: project
    } do
      %{spec_file: spec_file, test_file: test_file} =
        CodeMySpec.Utils.component_files(component, project)

      assert {:ok, prompt} = LiveViewTest.command(scope, task)
      assert prompt =~ spec_file
      assert prompt =~ test_file
    end

    test "includes parent component spec file path when parent exists", %{
      scope: scope,
      project: project
    } do
      parent =
        component_fixture(scope, %{
          name: "AccountsLive",
          type: "liveview",
          module_name: "TestAppWeb.AccountsLive",
          description: "Accounts section",
          project_id: project.id
        })

      child =
        component_fixture(scope, %{
          name: "SettingsLive",
          type: "liveview",
          module_name: "TestAppWeb.SettingsLive",
          description: "Settings page",
          parent_component_id: parent.id,
          project_id: project.id
        })

      child = Components.get_component(scope, child.id) |> Repo.preload(:parent_component)
      task = %{component_id: child.id, project_id: project.id, story_id: nil}

      %{spec_file: parent_spec_path} = CodeMySpec.Utils.component_files(parent, project)

      assert {:ok, prompt} = LiveViewTest.command(scope, task)
      assert prompt =~ parent_spec_path
    end

    test "includes TDD mode guidance when implementation doesn't exist", %{
      task: task,
      scope: scope
    } do
      assert {:ok, prompt} = LiveViewTest.command(scope, task)
      assert prompt =~ "TDD"
      assert prompt =~ "doesn't exist yet"
    end

    test "includes validation mode guidance when implementation exists", context do
      context = write_code_file(context)
      %{task: task, scope: scope, component: component} = context

      requirement_fixture(scope, component, %{
        name: "implementation_file",
        artifact_type: :code,
        description: "Component implementation file exists",
        satisfied: true
      })

      assert {:ok, prompt} = LiveViewTest.command(scope, task)
      assert prompt =~ "implementation already exists"
    end

    test "includes LiveView-specific test guidance (live/2, handle_event, rendered HTML)", %{
      task: task,
      scope: scope
    } do
      assert {:ok, prompt} = LiveViewTest.command(scope, task)
      assert prompt =~ "live" or prompt =~ "LiveView"
      assert prompt =~ "handle_event" or prompt =~ "event"
      assert prompt =~ "render" or prompt =~ "HTML"
    end

    test "includes test rules content in prompt", %{task: task, scope: scope} do
      assert {:ok, prompt} = LiveViewTest.command(scope, task)
      assert prompt =~ "Test Rules"
    end

  end

  # ============================================================================
  # evaluate/3 Tests
  # ============================================================================

  describe "evaluate/3" do
    setup [:create_scope, :create_project, :create_component, :create_task]

    test "returns {:ok, :valid} when all test requirements are satisfied and no blocking problems exist",
         %{task: task, scope: scope, component: component} do
      satisfy_test_requirements(scope, component)

      assert {:ok, :valid} = LiveViewTest.evaluate(scope, task)
    end

    test "returns {:ok, :invalid, feedback} when test file does not exist", %{
      task: task,
      scope: scope,
      component: component
    } do
      requirement_fixture(scope, component, %{
        name: "test_file",
        artifact_type: :tests,
        description: "Component test file exists",
        satisfied: false,
        details: %{reason: "File missing", path: "test/test_app_web/dashboard_live_test.exs"}
      })

      assert {:ok, :invalid, feedback} = LiveViewTest.evaluate(scope, task)
      assert feedback =~ "requirements not met"
    end

    test "returns {:ok, :invalid, feedback} when test spec alignment fails", %{
      task: task,
      scope: scope,
      component: component
    } do
      requirement_fixture(scope, component, %{
        name: "test_file",
        artifact_type: :tests,
        description: "Component test file exists",
        satisfied: true
      })

      requirement_fixture(scope, component, %{
        name: "test_spec_alignment",
        artifact_type: :tests,
        description: "Test file implements all spec test assertions",
        satisfied: false,
        details: %{reason: "Test alignment issues", problems: ["Missing test for mount/3"]}
      })

      assert {:ok, :invalid, feedback} = LiveViewTest.evaluate(scope, task)
      assert feedback =~ "requirements not met"
    end

    test "returns {:ok, :invalid, feedback} when compilation errors exist in test file", %{
      task: task,
      scope: scope,
      component: component,
      project: project
    } do
      satisfy_test_requirements(scope, component)
      %{test_file: test_file} = CodeMySpec.Utils.component_files(component, project)

      {:ok, _} =
        CodeMySpec.Problems.create_problems(scope, [
          %{
            severity: :error,
            source_type: :static_analysis,
            source: "compiler",
            file_path: test_file,
            message: "undefined function live/2",
            category: "undefined_function"
          }
        ])

      assert {:ok, :invalid, feedback} = LiveViewTest.evaluate(scope, task)
      assert feedback =~ "undefined function"
    end

    test "returns {:ok, :valid} even when test failures exist (TDD mode — test failures are filtered out)",
         %{task: task, scope: scope, component: component, project: project} do
      satisfy_test_requirements(scope, component)
      %{test_file: test_file} = CodeMySpec.Utils.component_files(component, project)

      {:ok, _} =
        CodeMySpec.Problems.create_problems(scope, [
          %{
            severity: :error,
            source_type: :test,
            source: "exunit",
            file_path: test_file,
            message: "test failed: expected view to have element",
            category: "test_failure"
          }
        ])

      assert {:ok, :valid} = LiveViewTest.evaluate(scope, task)
    end

    test "includes unsatisfied requirement details in feedback", %{
      task: task,
      scope: scope,
      component: component
    } do
      requirement_fixture(scope, component, %{
        name: "test_file",
        artifact_type: :tests,
        description: "Component test file exists",
        satisfied: false,
        details: %{reason: "File missing"}
      })

      assert {:ok, :invalid, feedback} = LiveViewTest.evaluate(scope, task)
      assert is_binary(feedback)
      assert String.length(feedback) > 0
    end

    test "includes problem details in feedback for non-test problems", %{
      task: task,
      scope: scope,
      component: component,
      project: project
    } do
      satisfy_test_requirements(scope, component)
      %{test_file: test_file} = CodeMySpec.Utils.component_files(component, project)

      {:ok, _} =
        CodeMySpec.Problems.create_problems(scope, [
          %{
            severity: :warning,
            source_type: :static_analysis,
            source: "credo",
            file_path: test_file,
            message: "Module has no @moduledoc",
            category: "readability"
          }
        ])

      assert {:ok, :invalid, feedback} = LiveViewTest.evaluate(scope, task)
      assert feedback =~ "moduledoc"
    end

    test "reloads component from database before checking requirements", %{
      task: task,
      scope: scope,
      component: component
    } do
      # Add requirements AFTER session is created — evaluate should still find them
      # because it reloads the component from the database
      requirement_fixture(scope, component, %{
        name: "test_file",
        artifact_type: :tests,
        description: "Component test file exists",
        satisfied: false,
        details: %{reason: "File missing"}
      })

      assert {:ok, :invalid, _feedback} = LiveViewTest.evaluate(scope, task)
    end
  end
end
