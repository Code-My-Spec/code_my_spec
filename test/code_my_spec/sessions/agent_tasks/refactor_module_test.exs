defmodule CodeMySpec.Sessions.AgentTasks.RefactorModuleTest do
  use CodeMySpec.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Sessions.AgentTasks.RefactorModule
  alias CodeMySpec.Components

  @moduletag :tmp_dir

  # ============================================================================
  # Setup
  # ============================================================================

  defp create_scope(_context) do
    scope = full_scope_fixture()
    %{scope: scope}
  end

  defp create_project(context) do
    %{scope: scope} = context
    # The full_scope_fixture already creates a project, so just use it
    project = scope.active_project

    Map.put(context, :project, project)
  end

  defp create_component(context, type \\ "module") do
    %{project: project, scope: scope} = context

    {:ok, component} =
      Components.create_component(scope, %{
        name: "TestModule",
        description: "A test module",
        type: type,
        module_name: "TestApp.TestModule",
        project_id: project.id
      })

    Map.put(context, :component, component)
  end

  defp create_context_with_children(context) do
    %{project: project, scope: scope} = context

    {:ok, parent_context} =
      Components.create_component(scope, %{
        name: "Accounts",
        description: "User account management",
        type: "context",
        module_name: "TestApp.Accounts",
        project_id: project.id
      })

    {:ok, child1} =
      Components.create_component(scope, %{
        name: "User",
        description: "User schema",
        type: "schema",
        module_name: "TestApp.Accounts.User",
        project_id: project.id,
        parent_component_id: parent_context.id
      })

    {:ok, child2} =
      Components.create_component(scope, %{
        name: "UserNotifier",
        description: "User email notifications",
        type: "module",
        module_name: "TestApp.Accounts.UserNotifier",
        project_id: project.id,
        parent_component_id: parent_context.id
      })

    context
    |> Map.put(:component, parent_context)
    |> Map.put(:child_components, [child1, child2])
  end

  defp create_session(context, opts \\ []) do
    %{project: project, component: component} = context
    working_dir = Keyword.get(opts, :working_dir, context[:tmp_dir])

    session = %{
      project: project,
      component: component,
      environment_type: :local,
      working_dir: working_dir
    }

    Map.put(context, :session, session)
  end

  defp write_files(%{skip_write_files: true} = context), do: context

  defp write_files(context) do
    %{component: component, project: project, session: session} = context
    %{spec_file: spec_file, code_file: code_file, test_file: test_file} =
      CodeMySpec.Utils.component_files(component, project)

    {:ok, environment} =
      CodeMySpec.Environments.create(session.environment_type, working_dir: session.working_dir)

    # Write sample files using environment
    CodeMySpec.Environments.write_file(environment, spec_file, """
    # #{component.name}

    ## Functions

    ### example/1
    An example function.

    ## Dependencies
    - Ecto
    """)

    CodeMySpec.Environments.write_file(environment, code_file, """
    defmodule #{component.module_name} do
      @moduledoc false

      def example(arg), do: {:ok, arg}
    end
    """)

    CodeMySpec.Environments.write_file(environment, test_file, """
    defmodule #{component.module_name}Test do
      use ExUnit.Case

      test "example/1" do
        assert {:ok, :result} = #{component.module_name}.example(:result)
      end
    end
    """)

    context
  end

  # ============================================================================
  # command/3 - Component Refactoring Tests
  # ============================================================================

  describe "command/3 for component refactoring" do
    setup [:create_scope, :create_project, :create_component, :create_session]

    setup :write_files

    test "returns {:ok, prompt} with instruction to ask user", %{session: session, scope: scope} do
      assert {:ok, prompt} = RefactorModule.command(scope, session)

      assert is_binary(prompt)
      assert prompt =~ "Start by asking the user"
    end

    test "includes spec file path and content in prompt", %{
      session: session,
      component: component,
      project: project,
      scope: scope
    } do
      %{spec_file: spec_file} = CodeMySpec.Utils.component_files(component, project)

      assert {:ok, prompt} = RefactorModule.command(scope, session)

      assert prompt =~ spec_file
      assert prompt =~ "Spec File:"
      # Should contain actual spec content
      assert prompt =~ "## Functions"
    end

    test "includes implementation file path and content in prompt", %{
      session: session,
      component: component,
      project: project,
      scope: scope
    } do
      %{code_file: code_file} = CodeMySpec.Utils.component_files(component, project)

      assert {:ok, prompt} = RefactorModule.command(scope, session)

      assert prompt =~ code_file
      assert prompt =~ "Implementation:"
      # Should contain actual code content
      assert prompt =~ "defmodule"
    end

    test "includes test file path and content in prompt", %{
      session: session,
      component: component,
      project: project,
      scope: scope
    } do
      %{test_file: test_file} = CodeMySpec.Utils.component_files(component, project)

      assert {:ok, prompt} = RefactorModule.command(scope, session)

      assert prompt =~ test_file
      assert prompt =~ "Tests:"
      # Should contain actual test content
      assert prompt =~ "use ExUnit.Case"
    end

    test "instructs agent to modify spec first, then tests, then code", %{session: session, scope: scope} do
      assert {:ok, prompt} = RefactorModule.command(scope, session)

      # Check for the ordering instruction
      assert prompt =~ "First update the spec"
      assert prompt =~ "Then update the tests"
      assert prompt =~ "Finally update the implementation"
    end

    @tag :skip_write_files
    test "handles missing spec file gracefully", %{
      session: session,
      scope: scope
    } do
      assert {:ok, prompt} = RefactorModule.command(scope, session)

      assert prompt =~ "(File does not exist yet)"
    end

    @tag :skip_write_files
    test "handles missing implementation file gracefully", %{
      session: session,
      scope: scope
    } do
      assert {:ok, prompt} = RefactorModule.command(scope, session)

      assert prompt =~ "(File does not exist yet)"
    end

    test "includes project context in prompt", %{session: session, project: project, scope: scope} do
      assert {:ok, prompt} = RefactorModule.command(scope, session)

      assert prompt =~ project.name
      assert prompt =~ "Project:"
    end

    test "includes component context in prompt", %{session: session, component: component, scope: scope} do
      assert {:ok, prompt} = RefactorModule.command(scope, session)

      assert prompt =~ component.name
      assert prompt =~ component.description
      assert prompt =~ component.type
    end

    test "includes design rules in prompt", %{session: session, scope: scope} do
      assert {:ok, prompt} = RefactorModule.command(scope, session)

      # Should include design rules section
      assert prompt =~ "Design Rules"
    end
  end

  # ============================================================================
  # command/3 - Context Refactoring Tests
  # ============================================================================

  describe "command/3 for context refactoring" do
    setup [:create_scope, :create_project, :create_context_with_children, :create_session]

    test "returns {:ok, prompt} for context type component", %{session: session, scope: scope} do
      assert {:ok, prompt} = RefactorModule.command(scope, session)

      assert is_binary(prompt)
      assert prompt =~ "bounded context"
    end

    test "includes context spec file path in prompt", %{
      session: session,
      component: context,
      project: project,
      scope: scope
    } do
      %{spec_file: spec_file} = CodeMySpec.Utils.component_files(context, project)

      assert {:ok, prompt} = RefactorModule.command(scope, session)

      assert prompt =~ spec_file
      assert prompt =~ "Context Spec:"
    end

    test "lists all child components in prompt", %{
      session: session,
      child_components: children,
      scope: scope
    } do
      assert {:ok, prompt} = RefactorModule.command(scope, session)

      assert prompt =~ "Child Components"

      for child <- children do
        assert prompt =~ child.name
        assert prompt =~ child.type
      end
    end

    test "includes child component file paths in prompt", %{
      session: session,
      child_components: [child1 | _],
      project: project,
      scope: scope
    } do
      %{spec_file: spec_file, code_file: code_file, test_file: test_file} =
        CodeMySpec.Utils.component_files(child1, project)

      assert {:ok, prompt} = RefactorModule.command(scope, session)

      assert prompt =~ spec_file
      assert prompt =~ code_file
      assert prompt =~ test_file
    end

    test "instructs agent to consider ripple effects on child components", %{session: session, scope: scope} do
      assert {:ok, prompt} = RefactorModule.command(scope, session)

      assert prompt =~ "child components"
      assert prompt =~ "ripple"
    end

    test "handles context with no children", %{session: session, scope: scope} do
      # Remove child components by creating a fresh context
      {:ok, empty_context} =
        Components.create_component(scope, %{
          name: "EmptyContext",
          description: "Context with no children",
          type: "context",
          module_name: "TestApp.EmptyContext",
          project_id: session.project.id
        })

      session = %{session | component: empty_context}

      assert {:ok, prompt} = RefactorModule.command(scope, session)

      assert prompt =~ "No child components"
    end
  end

  # ============================================================================
  # evaluate/3 Tests
  # ============================================================================

  describe "evaluate/3" do
    setup [:create_scope, :create_project, :create_component, :create_session]

    test "always returns {:ok, :valid}", %{session: session, scope: scope} do
      assert {:ok, :valid} = RefactorModule.evaluate(scope, session)
    end

    test "does not perform any file validation", %{session: session, scope: scope} do
      # Even with missing files, should return valid
      assert {:ok, :valid} = RefactorModule.evaluate(scope, session)
    end

    test "returns valid regardless of session state", %{session: session, scope: scope} do
      # Empty session still valid
      empty_session = %{}
      assert {:ok, :valid} = RefactorModule.evaluate(scope, empty_session)

      # Original session still valid
      assert {:ok, :valid} = RefactorModule.evaluate(scope, session)
    end
  end
end
