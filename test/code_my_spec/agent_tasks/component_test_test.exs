defmodule CodeMySpec.AgentTasks.ComponentTestTest do
  @moduledoc false
  use CodeMySpecTest.DataCase

  import CodeMySpec.UsersFixtures
  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.RequirementsFixtures

  alias CodeMySpec.AgentTasks.ComponentTest
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

  defp write_spec_file(context) do
    %{component: component, project: project, tmp_dir: tmp_dir} = context

    %{spec_file: spec_file} = CodeMySpec.Utils.component_files(component, project)
    full_path = Path.join(tmp_dir, spec_file)
    File.mkdir_p!(Path.dirname(full_path))

    content = """
    # #{component.name}

    ## Functions

    ### example/1

    An example function.

    ```elixir
    @spec example(term()) :: {:ok, term()}
    ```

    **Test Assertions**:
    - returns ok tuple with input
    - handles nil input

    ## Dependencies
    - Ecto
    """

    File.write!(full_path, content)
    context
  end

  defp write_test_file(context) do
    %{component: component, project: project, tmp_dir: tmp_dir} = context

    %{test_file: test_file} = CodeMySpec.Utils.component_files(component, project)
    full_path = Path.join(tmp_dir, test_file)
    File.mkdir_p!(Path.dirname(full_path))

    content = """
    defmodule #{component.module_name}Test do
      use ExUnit.Case

      describe "example/1" do
        test "returns ok tuple with input" do
          assert {:ok, :result} = #{component.module_name}.example(:result)
        end

        test "handles nil input" do
          assert {:ok, nil} = #{component.module_name}.example(nil)
        end
      end
    end
    """

    File.write!(full_path, content)
    context
  end

  defp write_code_file(context) do
    %{component: component, project: project, tmp_dir: tmp_dir} = context

    %{code_file: code_file} = CodeMySpec.Utils.component_files(component, project)
    full_path = Path.join(tmp_dir, code_file)
    File.mkdir_p!(Path.dirname(full_path))

    content = """
    defmodule #{component.module_name} do
      @moduledoc false

      def example(arg), do: {:ok, arg}
    end
    """

    File.write!(full_path, content)
    context
  end

  defp setup_all_files(context) do
    context
    |> write_spec_file()
    |> write_test_file()
    |> write_code_file()
  end

  # ============================================================================
  # command/3 Tests
  # ============================================================================

  describe "command/3" do
    setup [:create_scope, :create_project, :create_component, :create_session]

    test "returns prompt with component information", %{
      session: session,
      scope: scope,
      component: component
    } do
      assert {:ok, prompt} = ComponentTest.command(scope, session)

      assert is_binary(prompt)
      assert prompt =~ component.name
      assert prompt =~ component.type
    end

    test "includes test rules in prompt", %{session: session, scope: scope} do
      assert {:ok, prompt} = ComponentTest.command(scope, session)

      assert prompt =~ "Test Rules:"
    end

    test "includes similar components when available", %{
      session: session,
      scope: scope,
      project: project
    } do
      # Create a similar component (same type)
      _similar =
        component_fixture(scope, %{
          name: "SimilarModule",
          type: "module",
          module_name: "TestApp.SimilarModule",
          project_id: project.id
        })

      assert {:ok, prompt} = ComponentTest.command(scope, session)

      # The prompt should have a section for similar components
      assert prompt =~ "Similar Components"
    end

    test "indicates TDD mode when implementation doesn't exist", %{session: session, scope: scope} do
      # No code file written, so TDD mode should be indicated
      assert {:ok, prompt} = ComponentTest.command(scope, session)

      assert prompt =~ "TDD"
      assert prompt =~ "doesn't exist yet"
    end

    test "indicates validation mode when implementation exists", context do
      context = setup_all_files(context)
      %{session: session, scope: scope, component: component} = context

      # Create satisfied implementation_file requirement
      requirement_fixture(scope, component, %{
        name: "implementation_file",
        artifact_type: :code,
        description: "Component implementation file exists",
        satisfied: true
      })

      assert {:ok, prompt} = ComponentTest.command(scope, session)

      assert prompt =~ "implementation already exists"
      assert prompt =~ "validate the existing implementation"
    end

    test "includes spec file path and test file path", %{
      session: session,
      scope: scope,
      component: component,
      project: project
    } do
      %{spec_file: spec_file, test_file: test_file} =
        CodeMySpec.Utils.component_files(component, project)

      assert {:ok, prompt} = ComponentTest.command(scope, session)

      assert prompt =~ spec_file
      assert prompt =~ test_file
      assert prompt =~ "Component Design File:"
      assert prompt =~ "Write the test file to"
    end
  end

  # ============================================================================
  # evaluate/3 Tests
  # ============================================================================

  describe "evaluate/3" do
    setup [:create_scope, :create_project, :create_component, :create_session]

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

    test "returns invalid when test_file requirement is unsatisfied", %{
      session: session,
      scope: scope,
      component: component
    } do
      requirement_fixture(scope, component, %{
        name: "test_file",
        artifact_type: :tests,
        description: "Component test file exists",
        satisfied: false,
        details: %{reason: "File missing", path: "test/test_app/test_module_test.exs"}
      })

      assert {:ok, :invalid, feedback} = ComponentTest.evaluate(scope, session)
      assert feedback =~ "requirements not met"
    end

    test "returns invalid when test_spec_alignment requirement is unsatisfied", %{
      session: session,
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
        details: %{reason: "Test alignment issues", problems: ["Missing test for foo/1"]}
      })

      assert {:ok, :invalid, feedback} = ComponentTest.evaluate(scope, session)
      assert feedback =~ "requirements not met"
      assert feedback =~ "Test alignment issues"
    end

    test "returns valid when all test requirements satisfied and no problems", %{
      session: session,
      scope: scope,
      component: component
    } do
      satisfy_test_requirements(scope, component)

      assert {:ok, :valid} = ComponentTest.evaluate(scope, session)
    end

    test "returns valid when only test failure problems exist (TDD mode)", %{
      session: session,
      scope: scope,
      component: component,
      project: project
    } do
      satisfy_test_requirements(scope, component)
      %{test_file: test_file} = CodeMySpec.Utils.component_files(component, project)

      # Create a test failure problem — should be filtered out
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

      assert {:ok, :valid} = ComponentTest.evaluate(scope, session)
    end

    test "returns invalid when non-test problems exist", %{
      session: session,
      scope: scope,
      component: component,
      project: project
    } do
      satisfy_test_requirements(scope, component)
      %{test_file: test_file} = CodeMySpec.Utils.component_files(component, project)

      # Create a compilation problem — should NOT be filtered out
      {:ok, _} =
        CodeMySpec.Problems.create_problems(scope, [
          %{
            severity: :error,
            source_type: :static_analysis,
            source: "compiler",
            file_path: test_file,
            message: "undefined function foo/0",
            category: "undefined_function"
          }
        ])

      assert {:ok, :invalid, feedback} = ComponentTest.evaluate(scope, session)
      assert feedback =~ "undefined function"
    end

    test "filters out test failures but keeps other problems", %{
      session: session,
      scope: scope,
      component: component,
      project: project
    } do
      satisfy_test_requirements(scope, component)
      %{test_file: test_file} = CodeMySpec.Utils.component_files(component, project)

      # Create both a test failure and a credo problem
      {:ok, _} =
        CodeMySpec.Problems.create_problems(scope, [
          %{
            severity: :error,
            source_type: :test,
            source: "exunit",
            file_path: test_file,
            message: "test failed",
            category: "test_failure"
          },
          %{
            severity: :warning,
            source_type: :static_analysis,
            source: "credo",
            file_path: test_file,
            message: "Module has no @moduledoc",
            category: "readability"
          }
        ])

      assert {:ok, :invalid, feedback} = ComponentTest.evaluate(scope, session)
      assert feedback =~ "moduledoc"
    end
  end
end
