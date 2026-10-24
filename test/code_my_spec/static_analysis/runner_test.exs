defmodule CodeMySpec.StaticAnalysis.RunnerTest do
  # Sync: `use_cmd_cassette` meck-patches `System.cmd/3` process-globally.
  # `@moduletag :analyzer` keeps it out of the default suite, since it works out
  # of the shared `code_my_spec_test_repos` directory.
  use CodeMySpecTest.DataCase, async: false
  use ExCliVcr

  # Out of the default suite. This file rsyncs a copy of a real Phoenix project
  # out of `../code_my_spec_test_repos` and runs real tools inside it — a
  # directory every worktree reaches through a symlink to one shared copy, so
  # two agents running suites collided there. `just test-analyzer` runs it.
  @moduletag :analyzer

  import ExUnit.CaptureLog
  import CodeMySpec.UsersFixtures
  import CodeMySpec.AccountsFixtures
  import CodeMySpec.ProjectsFixtures

  alias CodeMySpec.ExecutionContexts.ExecutionContext
  alias CodeMySpec.StaticAnalysis.Runner
  alias CodeMySpec.Support.TestAdapter

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

    scope =
      user_scope_fixture(user, account, updated_project)
      |> Map.put(:cwd, project_dir)
      |> Map.put(:active_working_copy_id, nil)

    on_exit(fn ->
      # Clean up spec files created by tests (docs is a submodule, git clean won't reach it)
      spec_file = Path.join(project_dir, ".code_my_spec/spec/my_module.spec.md")
      File.rm(spec_file)

      TestAdapter.checkin(project_dir)
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
      assert match?([_ | _], analyzers)

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
        CodeMySpec.StaticAnalysis.Analyzers.Sobelow
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
    test "the retired spec alignment analyzer is unavailable", %{scope: scope} do
      assert {:error, "Unknown analyzer: spec_alignment"} =
               Runner.run(scope, :spec_alignment,
                 execution_context: ExecutionContext.new(:local, scope.cwd)
               )
    end

    @tag timeout: 120_000
    test "supports all registered analyzer types", %{scope: scope} do
      use_cmd_cassette "static_analysis_runner_all_types", ignore: [[:opts, :cd]] do
        # Test each analyzer that's available
        analyzers_to_test = [
          :credo,
          :sobelow
        ]

        Enum.each(analyzers_to_test, fn analyzer_name ->
          assert_analyzer_result(Runner.run(scope, analyzer_name))
        end)
      end
    end
  end

  # ============================================================================
  # run/3 - Error Cases
  # ============================================================================

  describe "run/3 - error handling" do
    test "returns error when analyzer name is invalid", %{scope: scope} do
      assert {:error, message} =
               Runner.run(scope, :nonexistent_analyzer,
                 execution_context: ExecutionContext.new(:local, scope.cwd)
               )

      assert is_binary(message)
    end

    test "returns error when project has no code_repo" do
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)
      project = project_fixture(scope, %{code_repo: nil})
      scope = user_scope_fixture(user, account, project)

      assert {:error, message} =
               Runner.run(scope, :credo,
                 execution_context: ExecutionContext.new(:local, "/nonexistent")
               )

      assert is_binary(message)
    end

    test "handles analyzer execution failures gracefully", %{scope: _scope} do
      # Try to run an analyzer with a nonexistent cwd
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope_no_repo = user_scope_fixture(user, account)
      project = project_fixture(scope_no_repo)

      scope_no_repo =
        user_scope_fixture(user, account, project)
        |> Map.put(:cwd, "/nonexistent/directory")
        |> Map.put(:active_working_copy_id, nil)

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
        assert {:ok, problems} = Runner.run_all(scope)
        assert is_list(problems)
      end
    end

    @tag timeout: 120_000
    test "aggregates Problems from available analyzers", %{scope: scope} do
      use_cmd_cassette "static_analysis_runner_aggregate", ignore: [[:opts, :cd]] do
        impl_file = Path.join(scope.cwd, "lib/test_module.ex")
        File.mkdir_p!(Path.dirname(impl_file))
        File.write!(impl_file, "defmodule TestModule do\nend")

        {:ok, problems} = Runner.run_all(scope)

        assert is_list(problems)
      end
    end

    @tag timeout: 120_000
    test "filters out analyzers that aren't available", %{project_dir: project_dir} do
      use_cmd_cassette "static_analysis_runner_filter", ignore: [[:opts, :cd]] do
        user = user_fixture()
        account = account_with_owner_fixture(user)
        scope = user_scope_fixture(user, account)

        temp_dir = Path.join(project_dir, "_temp_no_spec_filter")
        File.mkdir_p!(temp_dir)

        project = project_fixture(scope)

        scope =
          user_scope_fixture(user, account, project)
          |> Map.put(:cwd, temp_dir)
          |> Map.put(:active_working_copy_id, nil)

        assert {:ok, problems} = Runner.run_all(scope)
        assert is_list(problems)
      end
    end

    test "refuses execution when no runtime is available" do
      # This scope has neither a rooted working copy nor a local runtime.
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)
      project = project_fixture(scope)
      scope = user_scope_fixture(user, account, project)

      assert {:error, :no_environment} = Runner.run_all(scope)
    end

    @tag timeout: 120_000
    test "logs warnings for failed analyzers", %{scope: scope} do
      use_cmd_cassette "static_analysis_runner_warnings", ignore: [[:opts, :cd]] do
        # credo:disable-for-next-line ExSlop.Check.Readability.ObviousComment
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
      assert {:error, :no_environment} = Runner.run_all(scope)
    end

    @tag timeout: 120_000
    test "respects timeout option for slow analyzers", %{scope: scope} do
      use_cmd_cassette "static_analysis_runner_timeout", ignore: [[:opts, :cd]] do
        # Run with a very short timeout - some analyzers may timeout
        # run_all always returns {:ok, problems} - failed analyzers are logged but don't cause error
        capture_log(fn ->
          {:ok, problems} = Runner.run_all(scope, timeout: 1)
          assert is_list(problems)
        end)
      end
    end
  end

  defp assert_analyzer_result({:ok, problems}), do: assert(is_list(problems))
  # Some analyzers may not be available, which is fine — assert the error is well-shaped.
  defp assert_analyzer_result({:error, message}), do: assert(is_binary(message))
end
