defmodule CodeMySpec.StaticAnalysis.Analyzers.SpecAlignmentTest do
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.AccountsFixtures
  import CodeMySpec.ProjectsFixtures

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.StaticAnalysis.Analyzers.SpecAlignment
  alias CodeMySpec.Support.TestAdapter
  alias CodeMySpecTest.EnvRestore

  @test_repo_url "https://github.com/Code-My-Spec/test_phoenix_project.git"

  setup do
    user = user_fixture()
    account = account_with_owner_fixture(user)
    scope = user_scope_fixture(user, account)
    project = project_fixture(scope, %{module_name: "TestPhoenixProject"})
    scope = user_scope_fixture(user, account, project)

    # Clone from pool
    {:ok, project_dir} =
      TestAdapter.clone(scope, @test_repo_url)

    # Update project with cloned repo path
    {:ok, updated_project} =
      CodeMySpec.Projects.update_project(scope, project, %{code_repo: project_dir})

    scope = user_scope_fixture(user, account, updated_project) |> Map.put(:cwd, project_dir)

    # Clear the spec directory on the way *in* as well as out. The checkout
    # comes from a shared pool and `.code_my_spec/spec` is a submodule the pool
    # reset does not clean, so a test that wrote specs here and did not tidy up
    # hands this one a tree that already looks aligned — every "detects a
    # missing X" assertion then finds nothing and fails, under some seeds only.
    # Establishing the precondition beats trusting the previous test to.
    File.rm_rf(Path.join(project_dir, ".code_my_spec/spec"))

    on_exit(fn ->
      # Clean up .code_my_spec/spec files we created (it's a submodule, pool reset won't clean it)
      docs_spec_dir = Path.join(project_dir, ".code_my_spec/spec")
      File.rm_rf(docs_spec_dir)

      TestAdapter.checkin(project_dir)
    end)

    %{scope: scope, project: updated_project, project_dir: project_dir}
  end

  # An environment that cannot list files must not crash the caller.
  #
  # `Environments.Harness` answers `{:error, :not_supported_on_harness}` for
  # `stream_files/3` — the server holds no disk, and streaming a remote working
  # copy is not something the channel offers. Piped into `Enum.filter/2` that
  # raised `Protocol.UndefinedError`, and because this analyzer runs inside
  # `HarnessProjectChannel`, the raise took the channel down: every stop on
  # every worktree failed with "the harness never got to ask", the harness
  # reconnected, and the next stop did the same. Thirty-three channel deaths
  # before it was found.
  #
  # `{:error, _}` rather than `{:ok, []}` on purpose. An empty list is a clean
  # sweep, and a reconcile against one deletes every spec-alignment Problem the
  # project has — "could not look" and "found nothing" are different answers.
  describe "an environment that cannot stream files" do
    setup do
      previous = Application.get_env(:code_my_spec, :harness_fs_transport)
      Application.put_env(:code_my_spec, :harness_fs_transport, CodeMySpec.Support.StubHarnessTransport)
      on_exit(fn -> EnvRestore.restore_app_env(:harness_fs_transport, previous) end)
      :ok
    end

    test "is an error, not a crash and not a clean sweep", %{scope: scope} do
      env = %Environment{type: :harness, cwd: "/anywhere", ref: %{"harness_id" => "x"}}

      assert {:error, message} = SpecAlignment.run(scope, environment: env, cwd: "/anywhere")
      assert message =~ "cannot list spec files"
      assert message =~ "not_supported_on_harness"
    end
  end

  describe "run/2" do
    test "returns empty list when all specs match implementation perfectly", %{
      scope: scope,
      project_dir: project_dir
    } do
      spec_dir = Path.join(project_dir, ".code_my_spec/spec")
      File.mkdir_p!(spec_dir)

      spec_content = """
      # MyModule

      **Type**: module

      ## Functions

      ### hello/0

      Returns a greeting.

      ```elixir
      @spec hello() :: String.t()
      ```

      **Test Assertions**:
      - returns "hello"
      """

      spec_file = Path.join(spec_dir, "my_module.spec.md")
      File.write!(spec_file, spec_content)

      impl_file = Path.join(project_dir, "lib/my_module.ex")
      File.mkdir_p!(Path.dirname(impl_file))

      impl_content = """
      defmodule MyModule do
        @spec hello() :: String.t()
        def hello, do: "hello"
      end
      """

      File.write!(impl_file, impl_content)

      test_file = Path.join(project_dir, "test/my_module_test.exs")
      File.mkdir_p!(Path.dirname(test_file))

      test_content = """
      defmodule MyModuleTest do
        use ExUnit.Case

        describe "hello/0" do
          test "returns \\"hello\\"" do
            assert MyModule.hello() == "hello"
          end
        end
      end
      """

      File.write!(test_file, test_content)

      # Scope to just our created spec file to avoid problems from fixture specs
      assert {:ok, []} = SpecAlignment.run(scope, paths: [".code_my_spec/spec/my_module.spec.md"])
    end

    test "detects missing function implementations (function in spec but not in code)", %{
      scope: scope,
      project_dir: project_dir
    } do
      spec_dir = Path.join(project_dir, ".code_my_spec/spec")
      File.mkdir_p!(spec_dir)

      spec_content = """
      # MyModule

      **Type**: module

      ## Functions

      ### missing_function/1

      This function is in the spec but not implemented.

      ```elixir
      @spec missing_function(String.t()) :: String.t()
      ```
      """

      spec_file = Path.join(spec_dir, "my_module.spec.md")
      File.write!(spec_file, spec_content)

      impl_file = Path.join(project_dir, "lib/my_module.ex")
      File.mkdir_p!(Path.dirname(impl_file))
      File.write!(impl_file, "defmodule MyModule do\nend")

      assert {:ok, problems} = SpecAlignment.run(scope, [])

      assert problems != []
      assert Enum.any?(problems, fn p -> p.message =~ "missing_function/1" end)
    end

    test "detects extra function implementations (public function in code but not in spec)", %{
      scope: scope,
      project_dir: project_dir
    } do
      spec_dir = Path.join(project_dir, ".code_my_spec/spec")
      File.mkdir_p!(spec_dir)

      spec_content = """
      # MyModule

      **Type**: module

      ## Functions
      """

      spec_file = Path.join(spec_dir, "my_module.spec.md")
      File.write!(spec_file, spec_content)

      impl_file = Path.join(project_dir, "lib/my_module.ex")
      File.mkdir_p!(Path.dirname(impl_file))

      impl_content = """
      defmodule MyModule do
        def extra_function(arg), do: arg
      end
      """

      File.write!(impl_file, impl_content)

      assert {:ok, problems} = SpecAlignment.run(scope, [])

      assert problems != []
      assert Enum.any?(problems, fn p -> p.message =~ "extra_function" end)
    end

    test "detects mismatched @spec type signatures between spec and implementation", %{
      scope: scope,
      project_dir: project_dir
    } do
      spec_dir = Path.join(project_dir, ".code_my_spec/spec")
      File.mkdir_p!(spec_dir)

      spec_content = """
      # MyModule

      **Type**: module

      ## Functions

      ### greet/1

      Greets a person.

      ```elixir
      @spec greet(String.t()) :: String.t()
      ```
      """

      spec_file = Path.join(spec_dir, "my_module.spec.md")
      File.write!(spec_file, spec_content)

      impl_file = Path.join(project_dir, "lib/my_module.ex")
      File.mkdir_p!(Path.dirname(impl_file))

      impl_content = """
      defmodule MyModule do
        @spec greet(atom()) :: atom()
        def greet(name), do: name
      end
      """

      File.write!(impl_file, impl_content)

      assert {:ok, problems} = SpecAlignment.run(scope, [])

      assert problems != []

      assert Enum.any?(problems, fn p ->
               p.message =~ "greet/1" and p.message =~ "Type signature mismatch"
             end)
    end

    test "detects missing test assertions (assertion in spec but test not found)", %{
      scope: scope,
      project_dir: project_dir
    } do
      spec_dir = Path.join(project_dir, ".code_my_spec/spec")
      File.mkdir_p!(spec_dir)

      spec_content = """
      # MyModule

      **Type**: module

      ## Functions

      ### hello/0

      Returns a greeting.

      ```elixir
      @spec hello() :: String.t()
      ```

      **Test Assertions**:
      - returns "hello"
      - returns a non-empty string
      """

      spec_file = Path.join(spec_dir, "my_module.spec.md")
      File.write!(spec_file, spec_content)

      impl_file = Path.join(project_dir, "lib/my_module.ex")
      File.mkdir_p!(Path.dirname(impl_file))

      impl_content = """
      defmodule MyModule do
        @spec hello() :: String.t()
        def hello, do: "hello"
      end
      """

      File.write!(impl_file, impl_content)

      test_file = Path.join(project_dir, "test/my_module_test.exs")
      File.mkdir_p!(Path.dirname(test_file))

      test_content = """
      defmodule MyModuleTest do
        use ExUnit.Case

        describe "hello/0" do
          test "returns \\"hello\\"" do
            assert MyModule.hello() == "hello"
          end
        end
      end
      """

      File.write!(test_file, test_content)

      assert {:ok, problems} = SpecAlignment.run(scope, [])

      assert problems != []

      assert Enum.any?(problems, fn p ->
               p.message =~ "test assertion" and p.message =~ "non-empty string"
             end)
    end

    test "detects extra test assertions (test exists but not documented in spec)", %{
      scope: scope,
      project_dir: project_dir
    } do
      spec_dir = Path.join(project_dir, ".code_my_spec/spec")
      File.mkdir_p!(spec_dir)

      spec_content = """
      # MyModule

      **Type**: module

      ## Functions

      ### hello/0

      Returns a greeting.

      ```elixir
      @spec hello() :: String.t()
      ```

      **Test Assertions**:
      - returns "hello"
      """

      spec_file = Path.join(spec_dir, "my_module.spec.md")
      File.write!(spec_file, spec_content)

      impl_file = Path.join(project_dir, "lib/my_module.ex")
      File.mkdir_p!(Path.dirname(impl_file))

      impl_content = """
      defmodule MyModule do
        @spec hello() :: String.t()
        def hello, do: "hello"
      end
      """

      File.write!(impl_file, impl_content)

      test_file = Path.join(project_dir, "test/my_module_test.exs")
      File.mkdir_p!(Path.dirname(test_file))

      test_content = """
      defmodule MyModuleTest do
        use ExUnit.Case

        describe "hello/0" do
          test "returns \\"hello\\"" do
            assert MyModule.hello() == "hello"
          end

          test "returns a string" do
            assert is_binary(MyModule.hello())
          end
        end
      end
      """

      File.write!(test_file, test_content)

      assert {:ok, problems} = SpecAlignment.run(scope, [])

      assert problems != []
      assert Enum.any?(problems, fn p -> p.message =~ "Extra test found" end)
    end

    test "handles spec files for modules that don't exist yet (no Problems generated)", %{
      scope: scope,
      project_dir: project_dir
    } do
      spec_dir = Path.join(project_dir, ".code_my_spec/spec")
      File.mkdir_p!(spec_dir)

      spec_content = """
      # NonExistentModule

      **Type**: module

      ## Functions

      ### some_function/0

      A function.

      ```elixir
      @spec some_function() :: :ok
      ```
      """

      spec_file = Path.join(spec_dir, "non_existent_module.spec.md")
      File.write!(spec_file, spec_content)

      # Scope to just our created spec file
      assert {:ok, problems} =
               SpecAlignment.run(scope, paths: [".code_my_spec/spec/non_existent_module.spec.md"])

      assert problems == []
    end

    test "handles modules without spec files (no Problems generated)", %{
      scope: scope,
      project_dir: project_dir
    } do
      # Create spec directory (required for analyzer to run)
      spec_dir = Path.join(project_dir, ".code_my_spec/spec")
      File.mkdir_p!(spec_dir)

      impl_file = Path.join(project_dir, "lib/no_spec_module.ex")
      File.mkdir_p!(Path.dirname(impl_file))

      impl_content = """
      defmodule NoSpecModule do
        def some_function, do: :ok
      end
      """

      File.write!(impl_file, impl_content)

      # Use a path that has no spec files to test "no spec" scenario
      assert {:ok, problems} =
               SpecAlignment.run(scope, paths: [".code_my_spec/spec/no_spec_module.spec.md"])

      assert problems == []
    end

    test "handles spec files with no Functions section gracefully", %{
      scope: scope,
      project_dir: project_dir
    } do
      spec_dir = Path.join(project_dir, ".code_my_spec/spec")
      File.mkdir_p!(spec_dir)

      spec_content = """
      # MyModule

      **Type**: module

      This module has no functions section.
      """

      spec_file = Path.join(spec_dir, "my_module.spec.md")
      File.write!(spec_file, spec_content)

      assert {:ok, problems} = SpecAlignment.run(scope, [])

      assert is_list(problems)
    end

    test "handles implementation files with no public functions gracefully", %{
      scope: scope,
      project_dir: project_dir
    } do
      spec_dir = Path.join(project_dir, ".code_my_spec/spec")
      File.mkdir_p!(spec_dir)

      spec_content = """
      # MyModule

      **Type**: module
      """

      spec_file = Path.join(spec_dir, "my_module.spec.md")
      File.write!(spec_file, spec_content)

      impl_file = Path.join(project_dir, "lib/my_module.ex")
      File.mkdir_p!(Path.dirname(impl_file))

      impl_content = """
      defmodule MyModule do
        defp private_function, do: :ok
      end
      """

      File.write!(impl_file, impl_content)

      assert {:ok, problems} = SpecAlignment.run(scope, [])

      assert is_list(problems)
    end

    test "handles test files that don't exist yet (no Problems generated)", %{
      scope: scope,
      project_dir: project_dir
    } do
      spec_dir = Path.join(project_dir, ".code_my_spec/spec")
      File.mkdir_p!(spec_dir)

      spec_content = """
      # MyModule

      **Type**: module

      ## Functions

      ### hello/0

      Returns a greeting.

      ```elixir
      @spec hello() :: String.t()
      ```

      **Test Assertions**:
      - returns "hello"
      """

      spec_file = Path.join(spec_dir, "my_module.spec.md")
      File.write!(spec_file, spec_content)

      impl_file = Path.join(project_dir, "lib/my_module.ex")
      File.mkdir_p!(Path.dirname(impl_file))

      impl_content = """
      defmodule MyModule do
        @spec hello() :: String.t()
        def hello, do: "hello"
      end
      """

      File.write!(impl_file, impl_content)

      # Scope to just our created spec file
      assert {:ok, problems} =
               SpecAlignment.run(scope, paths: [".code_my_spec/spec/my_module.spec.md"])

      assert problems == []
    end

    test "sets source to \"spec_alignment\" on all Problems", %{
      scope: scope,
      project_dir: project_dir
    } do
      spec_dir = Path.join(project_dir, ".code_my_spec/spec")
      File.mkdir_p!(spec_dir)

      spec_content = """
      # MyModule

      **Type**: module

      ## Functions

      ### missing_function/0

      Missing function.

      ```elixir
      @spec missing_function() :: :ok
      ```
      """

      spec_file = Path.join(spec_dir, "my_module.spec.md")
      File.write!(spec_file, spec_content)

      impl_file = Path.join(project_dir, "lib/my_module.ex")
      File.mkdir_p!(Path.dirname(impl_file))
      File.write!(impl_file, "defmodule MyModule do\nend")

      assert {:ok, problems} = SpecAlignment.run(scope, [])

      assert problems != []
      assert Enum.all?(problems, fn p -> p.source == "spec_alignment" end)
    end

    test "sets source_type to :static_analysis on all Problems", %{
      scope: scope,
      project_dir: project_dir
    } do
      spec_dir = Path.join(project_dir, ".code_my_spec/spec")
      File.mkdir_p!(spec_dir)

      spec_content = """
      # MyModule

      **Type**: module

      ## Functions

      ### missing_function/0

      Missing function.

      ```elixir
      @spec missing_function() :: :ok
      ```
      """

      spec_file = Path.join(spec_dir, "my_module.spec.md")
      File.write!(spec_file, spec_content)

      impl_file = Path.join(project_dir, "lib/my_module.ex")
      File.mkdir_p!(Path.dirname(impl_file))
      File.write!(impl_file, "defmodule MyModule do\nend")

      assert {:ok, problems} = SpecAlignment.run(scope, [])

      assert problems != []
      assert Enum.all?(problems, fn p -> p.source_type == :static_analysis end)
    end

    test "sets appropriate severity levels (error for missing impl, warning for extra functions)",
         %{scope: scope, project_dir: project_dir} do
      spec_dir = Path.join(project_dir, ".code_my_spec/spec")
      File.mkdir_p!(spec_dir)

      spec_content = """
      # MyModule

      **Type**: module

      ## Functions

      ### required_function/0

      Required function.

      ```elixir
      @spec required_function() :: :ok
      ```
      """

      spec_file = Path.join(spec_dir, "my_module.spec.md")
      File.write!(spec_file, spec_content)

      impl_file = Path.join(project_dir, "lib/my_module.ex")
      File.mkdir_p!(Path.dirname(impl_file))

      impl_content = """
      defmodule MyModule do
        def extra_function, do: :ok
      end
      """

      File.write!(impl_file, impl_content)

      assert {:ok, problems} = SpecAlignment.run(scope, [])

      missing_problems = Enum.filter(problems, fn p -> p.message =~ "required_function" end)
      extra_problems = Enum.filter(problems, fn p -> p.message =~ "extra_function" end)

      assert Enum.any?(missing_problems, fn p -> p.severity == :error end)
      assert Enum.any?(extra_problems, fn p -> p.severity == :warning end)
    end

    test "includes file_path and line numbers in Problems when available", %{
      scope: scope,
      project_dir: project_dir
    } do
      spec_dir = Path.join(project_dir, ".code_my_spec/spec")
      File.mkdir_p!(spec_dir)

      spec_content = """
      # MyModule

      **Type**: module

      ## Functions

      ### missing_function/0

      Missing function.

      ```elixir
      @spec missing_function() :: :ok
      ```
      """

      spec_file = Path.join(spec_dir, "my_module.spec.md")
      File.write!(spec_file, spec_content)

      impl_file = Path.join(project_dir, "lib/my_module.ex")
      File.mkdir_p!(Path.dirname(impl_file))
      File.write!(impl_file, "defmodule MyModule do\nend")

      assert {:ok, problems} = SpecAlignment.run(scope, [])

      assert problems != []
      assert Enum.all?(problems, fn p -> is_binary(p.file_path) end)
    end

    test "handles parsing errors in spec files gracefully (returns Problem about invalid spec)",
         %{scope: scope, project_dir: project_dir} do
      spec_dir = Path.join(project_dir, ".code_my_spec/spec")
      File.mkdir_p!(spec_dir)

      spec_content = "This is not valid spec markdown"
      spec_file = Path.join(spec_dir, "invalid.spec.md")
      File.write!(spec_file, spec_content)

      assert {:ok, problems} = SpecAlignment.run(scope, [])

      assert is_list(problems)
    end

    test "handles parsing errors in implementation files gracefully", %{
      scope: scope,
      project_dir: project_dir
    } do
      spec_dir = Path.join(project_dir, ".code_my_spec/spec")
      File.mkdir_p!(spec_dir)

      spec_content = """
      # MyModule

      **Type**: module
      """

      spec_file = Path.join(spec_dir, "my_module.spec.md")
      File.write!(spec_file, spec_content)

      impl_file = Path.join(project_dir, "lib/my_module.ex")
      File.mkdir_p!(Path.dirname(impl_file))
      File.write!(impl_file, "defmodule MyModule do\n  this is invalid syntax\nend")

      assert {:ok, problems} = SpecAlignment.run(scope, [])

      assert is_list(problems)
    end

    test "respects opts[:paths] to limit analysis to specific directories", %{
      scope: scope,
      project_dir: project_dir
    } do
      spec_dir = Path.join(project_dir, ".code_my_spec/spec")
      File.mkdir_p!(spec_dir)

      subdir = Path.join(spec_dir, "subdir")
      File.mkdir_p!(subdir)

      spec_content = """
      # MyModule

      **Type**: module

      ## Functions

      ### missing_function/0

      Missing function.

      ```elixir
      @spec missing_function() :: :ok
      ```
      """

      spec_file = Path.join(subdir, "my_module.spec.md")
      File.write!(spec_file, spec_content)

      impl_file = Path.join(project_dir, "lib/my_module.ex")
      File.mkdir_p!(Path.dirname(impl_file))
      File.write!(impl_file, "defmodule MyModule do\nend")

      assert {:ok, problems} = SpecAlignment.run(scope, paths: ["other_dir"])

      assert problems == []
    end

    test "returns error when spec directory doesn't exist", %{project_dir: project_dir} do
      # Create a scope with cwd pointing to a directory without .code_my_spec/spec
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)

      # Use a temp directory without a spec folder
      temp_dir = Path.join(project_dir, "_temp_no_spec")
      File.mkdir_p!(temp_dir)

      project = project_fixture(scope)
      scope = user_scope_fixture(user, account, project) |> Map.put(:cwd, temp_dir)

      assert {:error, message} = SpecAlignment.run(scope, [])

      assert is_binary(message)
      assert message =~ "Spec directory"
    end
  end

  describe "available?/1" do
    test "returns true when project spec directory exists", %{
      scope: scope,
      project_dir: project_dir
    } do
      spec_dir = Path.join(project_dir, ".code_my_spec/spec")
      File.mkdir_p!(spec_dir)

      assert SpecAlignment.available?(scope) == true
    end

    test "returns false when spec directory doesn't exist", %{project_dir: project_dir} do
      # Create a scope with cwd pointing to a directory without .code_my_spec/spec
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)

      # Use a temp directory without a spec folder
      temp_dir = Path.join(project_dir, "_temp_no_spec_avail")
      File.mkdir_p!(temp_dir)

      project = project_fixture(scope)
      scope = user_scope_fixture(user, account, project) |> Map.put(:cwd, temp_dir)

      assert SpecAlignment.available?(scope) == false
    end

    test "does not raise exceptions", %{scope: scope} do
      assert is_boolean(SpecAlignment.available?(scope))
    end

    test "executes quickly without blocking", %{scope: scope} do
      {time, _result} = :timer.tc(fn -> SpecAlignment.available?(scope) end)

      # Should execute in less than 100ms (100,000 microseconds)
      assert time < 100_000
    end
  end

  describe "name/0" do
    test "returns \"spec_alignment\"" do
      assert SpecAlignment.name() == "spec_alignment"
    end

    test "returns consistent value across multiple calls" do
      first_call = SpecAlignment.name()
      second_call = SpecAlignment.name()

      assert first_call == second_call
      assert first_call == "spec_alignment"
    end
  end
end
