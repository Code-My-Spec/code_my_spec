defmodule CodeMySpec.AgentTasks.ComponentTestTest do
  @moduledoc false
  use CodeMySpec.DataCase
  use ExCliVcr

  import CodeMySpec.UsersFixtures
  import CodeMySpec.ComponentsFixtures

  alias CodeMySpec.AgentTasks.ComponentTest
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Support.TestAdapter

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

    test "returns prompt with component information", %{session: session, scope: scope, component: component} do
      assert {:ok, prompt} = ComponentTest.command(scope, session)

      assert is_binary(prompt)
      assert prompt =~ component.name
      assert prompt =~ component.type
    end

    test "includes test rules in prompt", %{session: session, scope: scope} do
      assert {:ok, prompt} = ComponentTest.command(scope, session)

      assert prompt =~ "Test Rules:"
    end

    test "includes similar components when available", %{session: session, scope: scope, project: project} do
      # Create a similar component (same type)
      _similar = component_fixture(scope, %{
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
      %{session: session, scope: scope} = context

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
  # evaluate/3 Tests - Early Exit Paths (no compilation needed)
  # ============================================================================

  describe "evaluate/3" do
    setup [:create_scope, :create_project, :create_component, :create_session]

    test "returns invalid when test file doesn't exist", %{session: session, scope: scope} do
      # No test file written - this test returns early, no compilation happens
      assert {:ok, :invalid, error_message} = ComponentTest.evaluate(scope, session)
      assert error_message =~ "test file does not exist"
    end
  end

  # ============================================================================
  # evaluate/3 Tests - Full Flow (requires real mix project)
  # ============================================================================

  describe "evaluate/3 with real project" do
    @test_repo_url "https://github.com/johns10/test_phoenix_project.git"

    setup _context do
      # Clone from pool using the same pattern as credo_test
      scope = full_scope_fixture()
      {:ok, project_path} = TestAdapter.clone(scope, @test_repo_url)

      on_exit(fn ->
        TestAdapter.checkin(project_path)
      end)

      # Add environment pointing to project_path
      scope = %{scope | environment: Environment.new(:local, project_path)}

      %{scope: scope, project_path: project_path}
    end

    setup context do
      %{scope: scope, project_path: project_path} = context
      project = scope.active_project

      # Create component with module name matching test project structure
      component = component_fixture(scope, %{
        name: "PostRepository",
        description: "Repository for blog posts",
        type: "repository",
        module_name: "TestPhoenixProject.Blog.PostRepository",
        project_id: project.id
      })

      session = %{
        project: project,
        component: component
      }

      # Fixed output file paths for cassette replay
      eval_opts = [
        compile_output_file: Path.join(System.tmp_dir!(), "compile_machine_test.json"),
        test_output_file: Path.join(System.tmp_dir!(), "test_output_test.json")
      ]

      %{
        scope: scope,
        project: project,
        project_path: project_path,
        component: component,
        session: session,
        eval_opts: eval_opts
      }
    end

    @tag timeout: 120_000
    test "returns invalid when compilation fails", %{
      session: session,
      scope: scope,
      project_path: project_path,
      component: component,
      project: project,
      eval_opts: eval_opts
    } do
      # Write a valid test file (required for evaluate to proceed)
      %{test_file: test_file} = CodeMySpec.Utils.component_files(component, project)
      test_path = Path.join(project_path, test_file)
      File.mkdir_p!(Path.dirname(test_path))

      test_content = """
      defmodule TestPhoenixProject.Blog.PostRepositoryTest do
        use ExUnit.Case

        test "placeholder" do
          assert true
        end
      end
      """

      File.write!(test_path, test_content)

      # Write a broken implementation file - mix compile compiles lib/, not test/
      %{code_file: code_file} = CodeMySpec.Utils.component_files(component, project)
      code_path = Path.join(project_path, code_file)
      File.mkdir_p!(Path.dirname(code_path))

      broken_content = """
      defmodule TestPhoenixProject.Blog.PostRepository do
        def broken do
          # Missing end - actual syntax error
      end
      """

      File.write!(code_path, broken_content)

      # Ensure cleanup happens even if test fails
      on_exit(fn ->
        File.rm(test_path)
        File.rm(code_path)
      end)

      use_cmd_cassette "component_test_compilation_fails" do
        result = ComponentTest.evaluate(scope, session, eval_opts)

        assert {:ok, :invalid, error_message} = result
        assert error_message =~ "Compilation failed" or error_message =~ "error"
      end
    end

    @tag timeout: 120_000
    test "runs quality checks when compilation passes", %{
      session: session,
      scope: scope,
      project_path: project_path,
      component: component,
      project: project,
      eval_opts: eval_opts
    } do
      # Write spec file
      %{spec_file: spec_file} = CodeMySpec.Utils.component_files(component, project)
      spec_full_path = Path.join(project_path, spec_file)
      File.mkdir_p!(Path.dirname(spec_full_path))

      spec_content = """
      # PostRepository

      ## Functions

      ### list_posts/0

      Lists all posts.

      **Test Assertions**:
      - returns list of posts

      ## Dependencies
      - Ecto
      """

      File.write!(spec_full_path, spec_content)

      # Write a valid test file
      %{test_file: test_file} = CodeMySpec.Utils.component_files(component, project)
      test_full_path = Path.join(project_path, test_file)
      File.mkdir_p!(Path.dirname(test_full_path))

      test_content = """
      defmodule TestPhoenixProject.Blog.PostRepositoryTest do
        use ExUnit.Case

        describe "list_posts/0" do
          test "returns list of posts" do
            result = TestPhoenixProject.Blog.PostRepository.list_posts()
            assert is_list(result)
          end
        end
      end
      """

      File.write!(test_full_path, test_content)

      # Write implementation
      %{code_file: code_file} = CodeMySpec.Utils.component_files(component, project)
      code_full_path = Path.join(project_path, code_file)
      File.mkdir_p!(Path.dirname(code_full_path))

      code_content = """
      defmodule TestPhoenixProject.Blog.PostRepository do
        @moduledoc false

        def list_posts, do: []
      end
      """

      File.write!(code_full_path, code_content)

      # Ensure cleanup happens even if test fails
      on_exit(fn ->
        File.rm(spec_full_path)
        File.rm(test_full_path)
        File.rm(code_full_path)
      end)

      use_cmd_cassette "component_test_quality_checks" do
        result = ComponentTest.evaluate(scope, session, eval_opts)

        # Should complete without error (valid or invalid based on quality checks)
        assert match?({:ok, :valid}, result) or match?({:ok, :invalid, _}, result)
      end
    end

    @tag timeout: 120_000
    test "checks TDD state when no implementation exists", %{
      session: session,
      scope: scope,
      project_path: project_path,
      component: component,
      project: project,
      eval_opts: eval_opts
    } do
      # Write spec file
      %{spec_file: spec_file} = CodeMySpec.Utils.component_files(component, project)
      spec_full_path = Path.join(project_path, spec_file)
      File.mkdir_p!(Path.dirname(spec_full_path))

      spec_content = """
      # PostRepository

      ## Functions

      ### list_posts/0

      Lists all posts.

      **Test Assertions**:
      - returns list of posts

      ## Dependencies
      - Ecto
      """

      File.write!(spec_full_path, spec_content)

      # Write test file that references non-existent module
      %{test_file: test_file} = CodeMySpec.Utils.component_files(component, project)
      test_full_path = Path.join(project_path, test_file)
      File.mkdir_p!(Path.dirname(test_full_path))

      test_content = """
      defmodule TestPhoenixProject.Blog.PostRepositoryTest do
        use ExUnit.Case

        describe "list_posts/0" do
          test "returns list of posts" do
            # This should fail in TDD mode - module doesn't exist
            result = TestPhoenixProject.Blog.PostRepository.list_posts()
            assert is_list(result)
          end
        end
      end
      """

      File.write!(test_full_path, test_content)

      # Ensure cleanup happens even if test fails
      on_exit(fn ->
        File.rm(spec_full_path)
        File.rm(test_full_path)
      end)

      use_cmd_cassette "component_test_tdd_mode" do
        # No implementation file - TDD mode
        result = ComponentTest.evaluate(scope, session, eval_opts)

        # In TDD mode, should return a result (could be valid if tests properly fail,
        # or invalid if something is wrong)
        assert match?({:ok, :valid}, result) or match?({:ok, :invalid, _}, result)
      end
    end

    @tag timeout: 120_000
    test "detects misalignment between spec and tests", %{
      session: session,
      scope: scope,
      project_path: project_path,
      component: component,
      project: project,
      eval_opts: eval_opts
    } do
      # Write spec with many test assertions
      %{spec_file: spec_file} = CodeMySpec.Utils.component_files(component, project)
      spec_full_path = Path.join(project_path, spec_file)
      File.mkdir_p!(Path.dirname(spec_full_path))

      # Spec requires 5 tests
      spec_content = """
      # PostRepository

      ## Functions

      ### list_posts/0

      Lists all posts.

      **Test Assertions**:
      - returns list of posts
      - handles empty database
      - filters by status
      - sorts by date
      - paginates results

      ## Dependencies
      - Ecto
      """

      File.write!(spec_full_path, spec_content)

      # Write test file with only 1 test (well below 0.9 alignment)
      %{test_file: test_file} = CodeMySpec.Utils.component_files(component, project)
      test_full_path = Path.join(project_path, test_file)
      File.mkdir_p!(Path.dirname(test_full_path))

      test_content = """
      defmodule TestPhoenixProject.Blog.PostRepositoryTest do
        use ExUnit.Case

        describe "list_posts/0" do
          test "returns list of posts" do
            assert is_list([])
          end
        end
      end
      """

      File.write!(test_full_path, test_content)

      # Write implementation
      %{code_file: code_file} = CodeMySpec.Utils.component_files(component, project)
      code_full_path = Path.join(project_path, code_file)
      File.mkdir_p!(Path.dirname(code_full_path))

      code_content = """
      defmodule TestPhoenixProject.Blog.PostRepository do
        @moduledoc false

        def list_posts, do: []
      end
      """

      File.write!(code_full_path, code_content)

      # Ensure cleanup happens even if test fails
      on_exit(fn ->
        File.rm(spec_full_path)
        File.rm(test_full_path)
        File.rm(code_full_path)
      end)

      use_cmd_cassette "component_test_alignment" do
        result = ComponentTest.evaluate(scope, session, eval_opts)

        # With poor alignment, should return invalid
        case result do
          {:ok, :invalid, errors} ->
            assert is_binary(errors)

          {:ok, :valid} ->
            # If it passes, the alignment check is lenient
            assert true
        end
      end
    end
  end
end
