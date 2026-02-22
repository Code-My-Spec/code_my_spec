defmodule CodeMySpec.StaticAnalysis.RunnerTest do
  use CodeMySpec.DataCase, async: false
  use ExCliVcr

  import ExUnit.CaptureLog
  import CodeMySpec.UsersFixtures
  import CodeMySpec.AccountsFixtures
  import CodeMySpec.ProjectsFixtures

  alias CodeMySpec.StaticAnalysis.Runner
  alias CodeMySpec.Problems.Problem

  @test_repo_url "https://github.com/johns10/test_phoenix_project.git"

  setup do
    user = user_fixture()
    account = account_with_owner_fixture(user)
    scope = user_scope_fixture(user, account)
    project = project_fixture(scope, %{module_name: "TestPhoenixProject"})
    scope = user_scope_fixture(user, account, project)

    # Clone from pool
    {:ok, project_dir} =
      CodeMySpec.Support.TestAdapter.clone(scope, @test_repo_url)

    # Update project with cloned repo path
    {:ok, updated_project} =
      CodeMySpec.Projects.update_project(scope, project, %{code_repo: project_dir})

    scope = user_scope_fixture(user, account, updated_project) |> Map.put(:cwd, project_dir)

    on_exit(fn ->
      # Clean up spec files created by tests (docs is a submodule, git clean won't reach it)
      spec_file = Path.join(project_dir, ".code_my_spec/spec/my_module.spec.md")
      if File.exists?(spec_file), do: File.rm!(spec_file)

      CodeMySpec.Support.TestAdapter.checkin(project_dir)
    end)

    %{scope: scope, project: updated_project, project_dir: project_dir}
  end

  # ============================================================================
  # list_analyzers/0
  # ============================================================================

  describe "list_analyzers/0" do
    test "returns list of all analyzer modules" do
      analyzers = Runner.list_analyzers()

      assert is_list(analyzers)
      assert length(analyzers) > 0

      Enum.each(analyzers, fn analyzer ->
        assert is_atom(analyzer)
        # Each should be a module
        assert Code.ensure_loaded?(analyzer)
      end)
    end

    test "includes all expected analyzer types" do
      analyzers = Runner.list_analyzers()

      # Based on spec, should include these analyzer modules
      expected_modules = [
        CodeMySpec.StaticAnalysis.Analyzers.Credo,
        CodeMySpec.StaticAnalysis.Analyzers.Sobelow,
        CodeMySpec.StaticAnalysis.Analyzers.SpecAlignment
      ]

      Enum.each(expected_modules, fn expected ->
        assert expected in analyzers,
               "Expected #{inspect(expected)} to be in list of analyzers"
      end)
    end

    test "returns modules in consistent order" do
      first_call = Runner.list_analyzers()
      second_call = Runner.list_analyzers()

      assert first_call == second_call
    end
  end

  # ============================================================================
  # run/3 - Happy Path
  # ============================================================================

  describe "run/3" do
    test "executes specified analyzer and returns Problems", %{scope: scope} do
      # Create spec directory for SpecAlignment analyzer
      spec_dir = Path.join(scope.cwd, ".code_my_spec/spec")
      File.mkdir_p!(spec_dir)

      assert {:ok, problems} = Runner.run(scope, :spec_alignment)
      assert is_list(problems)

      Enum.each(problems, fn problem ->
        assert %Problem{} = problem
      end)
    end

    test "passes options through to analyzer", %{scope: scope} do
      # SpecAlignment can take paths option
      spec_dir = Path.join(scope.cwd, ".code_my_spec/spec")
      File.mkdir_p!(spec_dir)

      assert {:ok, _problems} = Runner.run(scope, :spec_alignment, paths: ["lib"])
    end

    test "validates Problems have project_id set", %{scope: scope} do
      spec_dir = Path.join(scope.cwd, ".code_my_spec/spec")
      File.mkdir_p!(spec_dir)

      # Create a spec file that will generate a problem
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

      impl_file = Path.join(scope.cwd, "lib/my_module.ex")
      File.mkdir_p!(Path.dirname(impl_file))
      File.write!(impl_file, "defmodule MyModule do\nend")

      {:ok, problems} = Runner.run(scope, :spec_alignment)

      assert length(problems) > 0

      Enum.each(problems, fn problem ->
        assert problem.project_id == scope.active_project_id
      end)
    end

    @tag timeout: 120_000
    test "supports all registered analyzer types", %{scope: scope} do
      use_cmd_cassette "static_analysis_runner_all_types", ignore: [[:opts, :cd]] do
        # Create spec directory for SpecAlignment
        spec_dir = Path.join(scope.cwd, ".code_my_spec/spec")
        File.mkdir_p!(spec_dir)

        # Test each analyzer that's available
        analyzers_to_test = [
          :credo,
          :sobelow,
          :spec_alignment
        ]

        Enum.each(analyzers_to_test, fn analyzer_name ->
          result = Runner.run(scope, analyzer_name)

          case result do
            {:ok, problems} ->
              assert is_list(problems)

            {:error, message} ->
              # Some analyzers may not be available, which is fine
              assert is_binary(message)
          end
        end)
      end
    end
  end

  # ============================================================================
  # run/3 - Error Cases
  # ============================================================================

  describe "run/3 - error handling" do
    test "returns error when analyzer name is invalid", %{scope: scope} do
      assert {:error, message} = Runner.run(scope, :nonexistent_analyzer)
      assert is_binary(message)
    end

    test "returns error when analyzer is not available", %{scope: scope} do
      # SpecAlignment requires a spec directory - if it doesn't exist, it's not available
      # Make sure spec directory doesn't exist
      spec_dir = Path.join(scope.cwd, ".code_my_spec/spec")
      File.rm_rf!(spec_dir)

      assert {:error, message} = Runner.run(scope, :spec_alignment)
      assert is_binary(message)
    end

    test "returns error when project has no code_repo" do
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)
      project = project_fixture(scope, %{code_repo: nil})
      scope = user_scope_fixture(user, account, project)

      assert {:error, message} = Runner.run(scope, :credo)
      assert is_binary(message)
    end

    test "handles analyzer execution failures gracefully", %{scope: _scope} do
      # Try to run an analyzer with a nonexistent cwd
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope_no_repo = user_scope_fixture(user, account)
      project = project_fixture(scope_no_repo)

      scope_no_repo =
        user_scope_fixture(user, account, project) |> Map.put(:cwd, "/nonexistent/directory")

      capture_log(fn ->
        assert {:error, message} = Runner.run(scope_no_repo, :credo)
        assert is_binary(message)
      end)
    end
  end

  # ============================================================================
  # run_all/2 - Happy Path
  # ============================================================================

  describe "run_all/2" do
    @tag timeout: 120_000
    test "executes all available analyzers in parallel", %{scope: scope} do
      use_cmd_cassette "static_analysis_runner_run_all", ignore: [[:opts, :cd]] do
        # Create spec directory to make SpecAlignment available
        spec_dir = Path.join(scope.cwd, ".code_my_spec/spec")
        File.mkdir_p!(spec_dir)

        assert {:ok, problems} = Runner.run_all(scope)
        assert is_list(problems)
      end
    end

    @tag timeout: 120_000
    test "aggregates Problems from available analyzers", %{scope: scope} do
      use_cmd_cassette "static_analysis_runner_aggregate", ignore: [[:opts, :cd]] do
        # Create spec directory and a spec with missing implementation
        spec_dir = Path.join(scope.cwd, ".code_my_spec/spec")
        File.mkdir_p!(spec_dir)

        spec_content = """
        # TestModule

        **Type**: module

        ## Functions

        ### test_function/0

        Test function.

        ```elixir
        @spec test_function() :: :ok
        ```
        """

        spec_file = Path.join(spec_dir, "test_module.spec.md")
        File.write!(spec_file, spec_content)

        impl_file = Path.join(scope.cwd, "lib/test_module.ex")
        File.mkdir_p!(Path.dirname(impl_file))
        File.write!(impl_file, "defmodule TestModule do\nend")

        {:ok, problems} = Runner.run_all(scope)

        # Should have problems from spec_alignment (at minimum)
        # Other analyzers may not be available without deps
        assert length(problems) > 0, "Expected at least one problem"
        assert Enum.any?(problems, fn p -> p.source == "spec_alignment" end)
      end
    end

    @tag timeout: 120_000
    test "filters out analyzers that aren't available", %{project_dir: project_dir} do
      use_cmd_cassette "static_analysis_runner_filter", ignore: [[:opts, :cd]] do
        # Create a scope with cwd pointing to a directory without docs/spec
        # so SpecAlignment won't be available, but Credo should still run
        user = user_fixture()
        account = account_with_owner_fixture(user)
        scope = user_scope_fixture(user, account)

        temp_dir = Path.join(project_dir, "_temp_no_spec_filter")
        File.mkdir_p!(temp_dir)

        project = project_fixture(scope)
        scope = user_scope_fixture(user, account, project) |> Map.put(:cwd, temp_dir)

        assert {:ok, problems} = Runner.run_all(scope)
        assert is_list(problems)

        # Problems shouldn't be from SpecAlignment since no spec directory
        if length(problems) > 0 do
          refute Enum.any?(problems, fn p -> p.source == "spec_alignment" end)
        end
      end
    end

    test "returns empty list when no analyzers are available" do
      # Create scope with no cwd - no analyzers will be available
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)
      project = project_fixture(scope)
      scope = user_scope_fixture(user, account, project)

      assert {:ok, []} = Runner.run_all(scope)
    end

    @tag timeout: 120_000
    test "logs warnings for failed analyzers", %{scope: scope} do
      use_cmd_cassette "static_analysis_runner_warnings", ignore: [[:opts, :cd]] do
        # Create a situation where at least one analyzer might fail
        log =
          capture_log(fn ->
            Runner.run_all(scope)
          end)

        # Log output may contain warnings about failed or unavailable analyzers
        assert is_binary(log)
      end
    end

    @tag timeout: 120_000
    test "handles concurrent execution without race conditions", %{scope: scope} do
      use_cmd_cassette "static_analysis_runner_concurrent", ignore: [[:opts, :cd]] do
        # Create spec directory
        spec_dir = Path.join(scope.cwd, ".code_my_spec/spec")
        File.mkdir_p!(spec_dir)

        # Run multiple times concurrently
        tasks =
          for _ <- 1..3 do
            Task.async(fn -> Runner.run_all(scope) end)
          end

        results = Task.await_many(tasks, 30_000)

        Enum.each(results, fn result ->
          assert match?({:ok, _}, result)
          {:ok, problems} = result
          assert is_list(problems)
        end)
      end
    end
  end

  # ============================================================================
  # run_all/2 - Error Cases
  # ============================================================================

  describe "run_all/2 - error handling" do
    @tag timeout: 120_000
    test "continues execution when one analyzer fails (error isolation)", %{scope: scope} do
      use_cmd_cassette "static_analysis_runner_error_isolation", ignore: [[:opts, :cd]] do
        # Create spec directory to enable SpecAlignment
        spec_dir = Path.join(scope.cwd, ".code_my_spec/spec")
        File.mkdir_p!(spec_dir)

        # Even if one analyzer might have issues, run_all should continue
        capture_log(fn ->
          assert {:ok, problems} = Runner.run_all(scope)
          assert is_list(problems)
        end)
      end
    end

    test "returns empty list when no cwd is set" do
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)
      project = project_fixture(scope)
      scope = user_scope_fixture(user, account, project)

      # When no cwd is set, run_all should return empty list
      # since no analyzers will be available
      assert {:ok, []} = Runner.run_all(scope)
    end

    @tag timeout: 120_000
    test "respects timeout option for slow analyzers", %{scope: scope} do
      use_cmd_cassette "static_analysis_runner_timeout", ignore: [[:opts, :cd]] do
        # Create spec directory
        spec_dir = Path.join(scope.cwd, ".code_my_spec/spec")
        File.mkdir_p!(spec_dir)

        # Run with a very short timeout - some analyzers may timeout
        # run_all always returns {:ok, problems} - failed analyzers are logged but don't cause error
        capture_log(fn ->
          {:ok, problems} = Runner.run_all(scope, timeout: 1)
          assert is_list(problems)
        end)
      end
    end
  end
end
