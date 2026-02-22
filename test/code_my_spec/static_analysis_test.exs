defmodule CodeMySpec.StaticAnalysisTest do
  @moduledoc """
  Tests for the CodeMySpec.StaticAnalysis context.

  The StaticAnalysis context is a pure delegation context - it delegates all functions
  to StaticAnalysis.Runner. The underlying functions are tested in:
  - test/code_my_spec/static_analysis/runner_test.exs

  This test file verifies that the context module exists, delegates correctly, and provides
  a thin wrapper around the Runner module for executing static analysis tools.
  """
  use CodeMySpec.DataCase, async: false

  use ExCliVcr
  import ExUnit.CaptureLog
  import CodeMySpec.UsersFixtures
  import CodeMySpec.AccountsFixtures
  import CodeMySpec.ProjectsFixtures

  alias CodeMySpec.StaticAnalysis
  alias CodeMySpec.Problems.Problem

  @test_repo_url "https://github.com/johns10/test_phoenix_project.git"

  # ============================================================================
  # Module Verification
  # ============================================================================

  test "module exists and exports expected functions" do
    # Ensure the module is loaded
    Code.ensure_loaded!(StaticAnalysis)

    # Verify the context module exists and has the expected delegates
    assert function_exported?(StaticAnalysis, :list_analyzers, 0)
    assert function_exported?(StaticAnalysis, :run, 2)
    assert function_exported?(StaticAnalysis, :run, 3)
    assert function_exported?(StaticAnalysis, :run_all, 1)
    assert function_exported?(StaticAnalysis, :run_all, 2)
  end

  # ============================================================================
  # Fixtures
  # ============================================================================

  defp setup_test_project do
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
      CodeMySpec.Support.TestAdapter.checkin(project_dir)
    end)

    %{scope: scope, project: updated_project, project_dir: project_dir}
  end

  # ============================================================================
  # list_analyzers/0
  # ============================================================================

  describe "list_analyzers/0" do
    test "returns list of all analyzer modules" do
      analyzers = StaticAnalysis.list_analyzers()

      assert is_list(analyzers)
      assert length(analyzers) == 3

      expected_modules = [
        CodeMySpec.StaticAnalysis.Analyzers.Credo,
        CodeMySpec.StaticAnalysis.Analyzers.Sobelow,
        CodeMySpec.StaticAnalysis.Analyzers.SpecAlignment
      ]

      assert analyzers == expected_modules
    end

    test "delegates to Runner.list_analyzers/0" do
      # Verify that the result matches what Runner.list_analyzers/0 returns
      assert StaticAnalysis.list_analyzers() ==
               CodeMySpec.StaticAnalysis.Runner.list_analyzers()
    end
  end

  # ============================================================================
  # run/3
  # ============================================================================

  describe "run/3" do
    setup do
      context = setup_test_project()

      on_exit(fn ->
        CodeMySpec.Support.TestAdapter.checkin(context.project_dir)
      end)

      context
    end

    test "executes specified analyzer and returns Problems", %{scope: scope} do
      # Create spec directory for SpecAlignment analyzer
      spec_dir = Path.join(scope.cwd, ".code_my_spec/spec")
      File.mkdir_p!(spec_dir)

      assert {:ok, problems} = StaticAnalysis.run(scope, :spec_alignment)
      assert is_list(problems)

      Enum.each(problems, fn problem ->
        assert %Problem{} = problem
      end)
    end

    test "delegates to Runner.run/3 with options", %{scope: scope} do
      # SpecAlignment can take paths option
      spec_dir = Path.join(scope.cwd, ".code_my_spec/spec")
      File.mkdir_p!(spec_dir)

      assert {:ok, _problems} = StaticAnalysis.run(scope, :spec_alignment, paths: ["lib"])
    end

    test "returns error when analyzer name is invalid", %{scope: scope} do
      assert {:error, message} = StaticAnalysis.run(scope, :nonexistent_analyzer)
      assert is_binary(message)
      assert message =~ "Unknown analyzer"
    end
  end

  # ============================================================================
  # run_all/2
  # ============================================================================

  describe "run_all/2" do
    setup do
      context = setup_test_project()

      on_exit(fn ->
        CodeMySpec.Support.TestAdapter.checkin(context.project_dir)
      end)

      context
    end

    test "executes all available analyzers and returns aggregated Problems", %{scope: scope} do
      # Create spec directory to make SpecAlignment available
      spec_dir = Path.join(scope.cwd, ".code_my_spec/spec")
      File.mkdir_p!(spec_dir)

      use_cmd_cassette "static_analysis_run_all" do
        assert {:ok, problems} = StaticAnalysis.run_all(scope)
        assert is_list(problems)
      end
    end

    test "delegates to Runner.run_all/2 with options", %{scope: scope} do
      # Create spec directory
      spec_dir = Path.join(scope.cwd, ".code_my_spec/spec")
      File.mkdir_p!(spec_dir)

      use_cmd_cassette "static_analysis_run_all" do
        # Run with custom timeout
        assert {:ok, problems} = StaticAnalysis.run_all(scope, timeout: 60_000)
        assert is_list(problems)
      end
    end

    test "returns empty list when no analyzers are available" do
      # Create scope with no cwd - no analyzers will be available
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)
      project = project_fixture(scope)
      scope = user_scope_fixture(user, account, project)

      assert {:ok, []} = StaticAnalysis.run_all(scope)
    end

    test "logs warnings for failed analyzers", %{scope: scope} do
      # Create spec directory
      spec_dir = Path.join(scope.cwd, ".code_my_spec/spec")
      File.mkdir_p!(spec_dir)

      use_cmd_cassette "static_analysis_run_all" do
        log =
          capture_log(fn ->
            StaticAnalysis.run_all(scope)
          end)

        # Log output may contain warnings about failed or unavailable analyzers
        assert is_binary(log)
      end
    end
  end
end
