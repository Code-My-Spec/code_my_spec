defmodule CodeMySpec.StaticAnalysis.Analyzers.SpecAlignmentTest do
  # Sync: one describe block swaps `:harness_fs_transport` for
  # `Support.StubHarnessTransport`, and that key is global.
  #
  # `config/config.exs:49` points it at `CodeMySpec.Analysis`, and
  # `environments/harness_test.exs` — also async — asserts on what Analysis
  # answers for an unregistered id:
  #
  #     assert {:error, {:harness_not_registered, %{op: "read_file"}}} = result
  #
  # The stub answers `{:error, :harness_unreachable}` to every op but `stat`, so
  # an overlap gives that test the wrong error and a failure describing nothing
  # about the code under test.
  #
  # Found by tracing after `07c2c511`, which was the same defect on
  # `:deploy_key`. Three conditions have to hold for one of these to bite — the
  # key is read at runtime, another *async* test exercises the reading path, and
  # the swapped value changes that test's outcome — and all three hold here.
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.AccountsFixtures
  import CodeMySpec.ProjectsFixtures

  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Support.InMemoryEnvironment
  alias CodeMySpec.StaticAnalysis.Analyzers.SpecAlignment
  alias CodeMySpecTest.EnvRestore

  setup do
    user = user_fixture()
    account = account_with_owner_fixture(user)
    scope = user_scope_fixture(user, account)
    project = project_fixture(scope, %{module_name: "TestPhoenixProject"})
    scope = user_scope_fixture(user, account, project)

    # A filesystem this test owns outright, rather than a checkout it borrows.
    #
    # This used to clone a real repository from a shared pool and write into it,
    # which is what made every assertion below depend on the pool being clean.
    # `.code_my_spec/spec` is a submodule the pool's reset does not touch, so a
    # test that wrote specs and failed to tidy up handed the next one a tree
    # that already looked aligned — every "detects a missing X" assertion then
    # found nothing, under some seeds only. The answer was to clear the
    # directory on the way in *and* out, which is a cleanup that exists solely
    # because the test wrote somewhere it did not own.
    #
    # An in-memory environment is an Agent, created per test and discarded with
    # it. There is no shared directory, so there is nothing to clear, nothing to
    # check in, and no reason for this file to be synchronous. `SpecAlignment`
    # reads every file through `Environments` and already accepts `environment:`,
    # so nothing about the analyzer changes to be tested this way.
    {:ok, env} = InMemoryEnvironment.create()
    on_exit(fn -> InMemoryEnvironment.destroy(env) end)

    scope = user_scope_fixture(user, account, project) |> Map.put(:cwd, env.cwd)

    %{scope: scope, project: project, env: env}
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

      Application.put_env(
        :code_my_spec,
        :harness_fs_transport,
        CodeMySpec.Support.StubHarnessTransport
      )

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
      env: env
    } do
      spec_dir = ".code_my_spec/spec"

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
      :ok = Environments.write_file(env, spec_file, spec_content)

      impl_file = "lib/my_module.ex"

      impl_content = """
      defmodule MyModule do
        @spec hello() :: String.t()
        def hello, do: "hello"
      end
      """

      :ok = Environments.write_file(env, impl_file, impl_content)

      test_file = "test/my_module_test.exs"

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

      :ok = Environments.write_file(env, test_file, test_content)

      # Scope to just our created spec file to avoid problems from fixture specs
      assert {:ok, []} =
               SpecAlignment.run(scope,
                 environment: env,
                 cwd: env.cwd,
                 paths: [".code_my_spec/spec/my_module.spec.md"]
               )
    end

    test "detects missing function implementations (function in spec but not in code)", %{
      scope: scope,
      env: env
    } do
      spec_dir = ".code_my_spec/spec"

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
      :ok = Environments.write_file(env, spec_file, spec_content)

      impl_file = "lib/my_module.ex"
      :ok = Environments.write_file(env, impl_file, "defmodule MyModule do\nend")

      assert {:ok, problems} = SpecAlignment.run(scope, environment: env, cwd: env.cwd)

      assert problems != []
      assert Enum.any?(problems, fn p -> p.message =~ "missing_function/1" end)
    end

    test "detects extra function implementations (public function in code but not in spec)", %{
      scope: scope,
      env: env
    } do
      spec_dir = ".code_my_spec/spec"

      spec_content = """
      # MyModule

      **Type**: module

      ## Functions
      """

      spec_file = Path.join(spec_dir, "my_module.spec.md")
      :ok = Environments.write_file(env, spec_file, spec_content)

      impl_file = "lib/my_module.ex"

      impl_content = """
      defmodule MyModule do
        def extra_function(arg), do: arg
      end
      """

      :ok = Environments.write_file(env, impl_file, impl_content)

      assert {:ok, problems} = SpecAlignment.run(scope, environment: env, cwd: env.cwd)

      assert problems != []
      assert Enum.any?(problems, fn p -> p.message =~ "extra_function" end)
    end

    test "detects mismatched @spec type signatures between spec and implementation", %{
      scope: scope,
      env: env
    } do
      spec_dir = ".code_my_spec/spec"

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
      :ok = Environments.write_file(env, spec_file, spec_content)

      impl_file = "lib/my_module.ex"

      impl_content = """
      defmodule MyModule do
        @spec greet(atom()) :: atom()
        def greet(name), do: name
      end
      """

      :ok = Environments.write_file(env, impl_file, impl_content)

      assert {:ok, problems} = SpecAlignment.run(scope, environment: env, cwd: env.cwd)

      assert problems != []

      assert Enum.any?(problems, fn p ->
               p.message =~ "greet/1" and p.message =~ "Type signature mismatch"
             end)
    end

    test "detects missing test assertions (assertion in spec but test not found)", %{
      scope: scope,
      env: env
    } do
      spec_dir = ".code_my_spec/spec"

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
      :ok = Environments.write_file(env, spec_file, spec_content)

      impl_file = "lib/my_module.ex"

      impl_content = """
      defmodule MyModule do
        @spec hello() :: String.t()
        def hello, do: "hello"
      end
      """

      :ok = Environments.write_file(env, impl_file, impl_content)

      test_file = "test/my_module_test.exs"

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

      :ok = Environments.write_file(env, test_file, test_content)

      assert {:ok, problems} = SpecAlignment.run(scope, environment: env, cwd: env.cwd)

      assert problems != []

      assert Enum.any?(problems, fn p ->
               p.message =~ "test assertion" and p.message =~ "non-empty string"
             end)
    end

    test "detects extra test assertions (test exists but not documented in spec)", %{
      scope: scope,
      env: env
    } do
      spec_dir = ".code_my_spec/spec"

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
      :ok = Environments.write_file(env, spec_file, spec_content)

      impl_file = "lib/my_module.ex"

      impl_content = """
      defmodule MyModule do
        @spec hello() :: String.t()
        def hello, do: "hello"
      end
      """

      :ok = Environments.write_file(env, impl_file, impl_content)

      test_file = "test/my_module_test.exs"

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

      :ok = Environments.write_file(env, test_file, test_content)

      assert {:ok, problems} = SpecAlignment.run(scope, environment: env, cwd: env.cwd)

      assert problems != []
      assert Enum.any?(problems, fn p -> p.message =~ "Extra test found" end)
    end

    test "handles spec files for modules that don't exist yet (no Problems generated)", %{
      scope: scope,
      env: env
    } do
      spec_dir = ".code_my_spec/spec"

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
      :ok = Environments.write_file(env, spec_file, spec_content)

      # Scope to just our created spec file
      assert {:ok, problems} =
               SpecAlignment.run(scope,
                 environment: env,
                 cwd: env.cwd,
                 paths: [".code_my_spec/spec/non_existent_module.spec.md"]
               )

      assert problems == []
    end

    test "handles modules without spec files (no Problems generated)", %{
      scope: scope,
      env: env
    } do
      # Create spec directory (required for analyzer to run)
      spec_dir = ".code_my_spec/spec"

      impl_file = "lib/no_spec_module.ex"

      impl_content = """
      defmodule NoSpecModule do
        def some_function, do: :ok
      end
      """

      :ok = Environments.write_file(env, impl_file, impl_content)

      # Use a path that has no spec files to test "no spec" scenario
      assert {:ok, problems} =
               SpecAlignment.run(scope,
                 environment: env,
                 cwd: env.cwd,
                 paths: [".code_my_spec/spec/no_spec_module.spec.md"]
               )

      assert problems == []
    end

    test "handles spec files with no Functions section gracefully", %{
      scope: scope,
      env: env
    } do
      spec_dir = ".code_my_spec/spec"

      spec_content = """
      # MyModule

      **Type**: module

      This module has no functions section.
      """

      spec_file = Path.join(spec_dir, "my_module.spec.md")
      :ok = Environments.write_file(env, spec_file, spec_content)

      assert {:ok, problems} = SpecAlignment.run(scope, environment: env, cwd: env.cwd)

      assert is_list(problems)
    end

    test "handles implementation files with no public functions gracefully", %{
      scope: scope,
      env: env
    } do
      spec_dir = ".code_my_spec/spec"

      spec_content = """
      # MyModule

      **Type**: module
      """

      spec_file = Path.join(spec_dir, "my_module.spec.md")
      :ok = Environments.write_file(env, spec_file, spec_content)

      impl_file = "lib/my_module.ex"

      impl_content = """
      defmodule MyModule do
        defp private_function, do: :ok
      end
      """

      :ok = Environments.write_file(env, impl_file, impl_content)

      assert {:ok, problems} = SpecAlignment.run(scope, environment: env, cwd: env.cwd)

      assert is_list(problems)
    end

    test "handles test files that don't exist yet (no Problems generated)", %{
      scope: scope,
      env: env
    } do
      spec_dir = ".code_my_spec/spec"

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
      :ok = Environments.write_file(env, spec_file, spec_content)

      impl_file = "lib/my_module.ex"

      impl_content = """
      defmodule MyModule do
        @spec hello() :: String.t()
        def hello, do: "hello"
      end
      """

      :ok = Environments.write_file(env, impl_file, impl_content)

      # Scope to just our created spec file
      assert {:ok, problems} =
               SpecAlignment.run(scope,
                 environment: env,
                 cwd: env.cwd,
                 paths: [".code_my_spec/spec/my_module.spec.md"]
               )

      assert problems == []
    end

    test "sets source to \"spec_alignment\" on all Problems", %{
      scope: scope,
      env: env
    } do
      spec_dir = ".code_my_spec/spec"

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
      :ok = Environments.write_file(env, spec_file, spec_content)

      impl_file = "lib/my_module.ex"
      :ok = Environments.write_file(env, impl_file, "defmodule MyModule do\nend")

      assert {:ok, problems} = SpecAlignment.run(scope, environment: env, cwd: env.cwd)

      assert problems != []
      assert Enum.all?(problems, fn p -> p.source == "spec_alignment" end)
    end

    test "sets source_type to :static_analysis on all Problems", %{
      scope: scope,
      env: env
    } do
      spec_dir = ".code_my_spec/spec"

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
      :ok = Environments.write_file(env, spec_file, spec_content)

      impl_file = "lib/my_module.ex"
      :ok = Environments.write_file(env, impl_file, "defmodule MyModule do\nend")

      assert {:ok, problems} = SpecAlignment.run(scope, environment: env, cwd: env.cwd)

      assert problems != []
      assert Enum.all?(problems, fn p -> p.source_type == :static_analysis end)
    end

    test "sets appropriate severity levels (error for missing impl, warning for extra functions)",
         %{scope: scope, env: env} do
      spec_dir = ".code_my_spec/spec"

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
      :ok = Environments.write_file(env, spec_file, spec_content)

      impl_file = "lib/my_module.ex"

      impl_content = """
      defmodule MyModule do
        def extra_function, do: :ok
      end
      """

      :ok = Environments.write_file(env, impl_file, impl_content)

      assert {:ok, problems} = SpecAlignment.run(scope, environment: env, cwd: env.cwd)

      missing_problems = Enum.filter(problems, fn p -> p.message =~ "required_function" end)
      extra_problems = Enum.filter(problems, fn p -> p.message =~ "extra_function" end)

      assert Enum.any?(missing_problems, fn p -> p.severity == :error end)
      assert Enum.any?(extra_problems, fn p -> p.severity == :warning end)
    end

    test "includes file_path and line numbers in Problems when available", %{
      scope: scope,
      env: env
    } do
      spec_dir = ".code_my_spec/spec"

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
      :ok = Environments.write_file(env, spec_file, spec_content)

      impl_file = "lib/my_module.ex"
      :ok = Environments.write_file(env, impl_file, "defmodule MyModule do\nend")

      assert {:ok, problems} = SpecAlignment.run(scope, environment: env, cwd: env.cwd)

      assert problems != []
      assert Enum.all?(problems, fn p -> is_binary(p.file_path) end)
    end

    test "handles parsing errors in spec files gracefully (returns Problem about invalid spec)",
         %{scope: scope, env: env} do
      spec_dir = ".code_my_spec/spec"

      spec_content = "This is not valid spec markdown"
      spec_file = Path.join(spec_dir, "invalid.spec.md")
      :ok = Environments.write_file(env, spec_file, spec_content)

      assert {:ok, problems} = SpecAlignment.run(scope, environment: env, cwd: env.cwd)

      assert is_list(problems)
    end

    test "handles parsing errors in implementation files gracefully", %{
      scope: scope,
      env: env
    } do
      spec_dir = ".code_my_spec/spec"

      spec_content = """
      # MyModule

      **Type**: module
      """

      spec_file = Path.join(spec_dir, "my_module.spec.md")
      :ok = Environments.write_file(env, spec_file, spec_content)

      impl_file = "lib/my_module.ex"

      :ok =
        Environments.write_file(
          env,
          impl_file,
          "defmodule MyModule do\n  this is invalid syntax\nend"
        )

      assert {:ok, problems} = SpecAlignment.run(scope, environment: env, cwd: env.cwd)

      assert is_list(problems)
    end

    test "respects opts[:paths] to limit analysis to specific directories", %{
      scope: scope,
      env: env
    } do
      spec_dir = ".code_my_spec/spec"

      subdir = Path.join(spec_dir, "subdir")

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
      :ok = Environments.write_file(env, spec_file, spec_content)

      impl_file = "lib/my_module.ex"
      :ok = Environments.write_file(env, impl_file, "defmodule MyModule do\nend")

      assert {:ok, problems} =
               SpecAlignment.run(scope, environment: env, cwd: env.cwd, paths: ["other_dir"])

      assert problems == []
    end

    test "returns error when spec directory doesn't exist", %{env: env} do
      # Create a scope with cwd pointing to a directory without .code_my_spec/spec
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)

      # Use a temp directory without a spec folder
      temp_dir = "_temp_no_spec"

      project = project_fixture(scope)
      scope = user_scope_fixture(user, account, project) |> Map.put(:cwd, temp_dir)

      assert {:error, message} = SpecAlignment.run(scope, environment: env, cwd: env.cwd)

      assert is_binary(message)
      assert message =~ "Spec directory"
    end
  end

  describe "available?/1" do
    # The one test in this file that needs a real directory, and it needs one
    # honestly: `available?/1` asks whether this analyzer can run *here*, and
    # answers by resolving the environment from the scope's cwd with no opts —
    # so there is nowhere to inject a memory environment, by design. A question
    # about the filesystem is answered by the filesystem.
    #
    # Unique per test rather than a fixed name, so it stays async-safe.
    test "returns true when project spec directory exists", %{scope: scope} do
      {:ok, dir} = Briefly.create(directory: true)
      File.mkdir_p!(Path.join(dir, ".code_my_spec/spec"))

      assert SpecAlignment.available?(%{scope | cwd: dir}) == true
    end

    test "returns false when spec directory doesn't exist", %{env: env} do
      # Create a scope with cwd pointing to a directory without .code_my_spec/spec
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)

      # Use a temp directory without a spec folder
      temp_dir = "_temp_no_spec_avail"

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
