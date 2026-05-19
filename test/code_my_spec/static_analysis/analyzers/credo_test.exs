defmodule CodeMySpec.StaticAnalysis.Analyzers.CredoTest do
  use CodeMySpecTest.DataCase

  use ExCliVcr
  import ExUnit.CaptureLog
  import CodeMySpec.{UsersFixtures, AccountsFixtures, ProjectsFixtures}

  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.StaticAnalysis.Analyzers.Credo
  alias CodeMySpec.Support.TestAdapter

  @test_repo_url "https://github.com/Code-My-Spec/test_phoenix_project.git"

  setup do
    user = user_fixture()
    account = account_with_owner_fixture(user)
    scope = user_scope_fixture(user, account)
    project = project_fixture(scope, %{module_name: "TestPhoenixProject"})
    scope = user_scope_fixture(user, account, project)

    # Clone from pool (fast reuse instead of rsync each time)
    {:ok, project_dir} = TestAdapter.clone(scope, @test_repo_url)

    # Update project with cloned repo path
    {:ok, updated_project} =
      CodeMySpec.Projects.update_project(scope, project, %{code_repo: project_dir})

    scope = user_scope_fixture(user, account, updated_project) |> Map.put(:cwd, project_dir)

    on_exit(fn ->
      TestAdapter.checkin(project_dir)
    end)

    %{scope: scope, project: updated_project, project_dir: project_dir}
  end

  # ============================================================================
  # name/0
  # ============================================================================

  describe "name/0" do
    test "returns \"credo\"" do
      assert Credo.name() == "credo"
    end

    test "returns consistent value across calls" do
      first_call = Credo.name()
      second_call = Credo.name()

      assert first_call == second_call
      assert first_call == "credo"
    end

    test "value matches source field in generated Problems" do
      issue = credo_issue_fixture()
      problem = CodeMySpec.Problems.from_credo(issue)

      assert problem.source == Credo.name()
    end
  end

  # ============================================================================
  # available?/1
  # ============================================================================

  describe "available?/1" do
    test "returns true when Credo deps directory exists", %{
      scope: scope,
      project_dir: project_dir
    } do
      # Create deps/credo directory to simulate credo being installed
      credo_deps_path = Path.join(project_dir, "deps/credo")
      File.mkdir_p!(credo_deps_path)

      assert Credo.available?(scope) == true
    end

    test "returns false when scope has no cwd" do
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)
      project = project_fixture(scope)
      scope = user_scope_fixture(user, account, project)

      assert Credo.available?(scope) == false
    end

    test "returns false when cwd directory doesn't exist" do
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)
      project = project_fixture(scope)

      scope =
        user_scope_fixture(user, account, project) |> Map.put(:cwd, "/nonexistent/directory")

      assert Credo.available?(scope) == false
    end

    test "returns false when mix.exs doesn't exist" do
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)

      project_dir =
        System.tmp_dir!() |> Path.join("credo_no_mix_#{System.unique_integer([:positive])}")

      File.mkdir_p!(project_dir)

      project = project_fixture(scope)
      scope = user_scope_fixture(user, account, project) |> Map.put(:cwd, project_dir)

      result = Credo.available?(scope)
      File.rm_rf!(project_dir)

      assert result == false
    end

    test "does not raise exceptions" do
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)
      project = project_fixture(scope)
      scope = user_scope_fixture(user, account, project) |> Map.put(:cwd, "/nonexistent")

      assert Credo.available?(scope) == false
    end

    test "executes quickly (< 1 second)" do
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)
      project = project_fixture(scope)
      scope = user_scope_fixture(user, account, project) |> Map.put(:cwd, "/nonexistent")

      {time_microseconds, _result} = :timer.tc(fn -> Credo.available?(scope) end)
      time_seconds = time_microseconds / 1_000_000

      assert time_seconds < 1.0
    end

    test "handles empty cwd gracefully" do
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)
      project = project_fixture(scope)
      scope = user_scope_fixture(user, account, project) |> Map.put(:cwd, "")

      capture_log(fn ->
        assert Credo.available?(scope) == false
      end)
    end
  end

  # ============================================================================
  # run/2 - Happy Path
  # ============================================================================

  describe "run/2" do
    @tag timeout: 120_000
    test "returns {:ok, list(Problem.t())} when Credo runs", %{scope: scope} do
      use_cmd_cassette "static_analysis_credo_run", ignore: [[:opts, :cd]] do
        {:ok, problems} = Credo.run(scope)

        assert is_list(problems)
        assert problems != []

        Enum.each(problems, fn problem ->
          assert %Problem{} = problem
        end)
      end
    end

    @tag timeout: 120_000
    test "each Problem has source set to \"credo\"", %{scope: scope} do
      use_cmd_cassette "static_analysis_credo_run", ignore: [[:opts, :cd]] do
        {:ok, problems} = Credo.run(scope)

        Enum.each(problems, fn problem ->
          assert problem.source == "credo"
        end)
      end
    end

    @tag timeout: 120_000
    test "each Problem has source_type set to :static_analysis", %{scope: scope} do
      use_cmd_cassette "static_analysis_credo_run", ignore: [[:opts, :cd]] do
        {:ok, problems} = Credo.run(scope)

        Enum.each(problems, fn problem ->
          assert problem.source_type == :static_analysis
        end)
      end
    end

    @tag timeout: 120_000
    test "each Problem has valid file_path relative to project root", %{scope: scope} do
      use_cmd_cassette "static_analysis_credo_run", ignore: [[:opts, :cd]] do
        {:ok, problems} = Credo.run(scope)

        Enum.each(problems, fn problem ->
          assert is_binary(problem.file_path)
        end)
      end
    end

    @tag timeout: 120_000
    test "each Problem has project_id matching scope project", %{scope: scope} do
      use_cmd_cassette "static_analysis_credo_run", ignore: [[:opts, :cd]] do
        {:ok, problems} = Credo.run(scope)

        Enum.each(problems, fn problem ->
          assert problem.project_id == scope.active_project_id
        end)
      end
    end

    test "each Problem has severity mapped from Credo priority (>= 10: error)" do
      issue = credo_issue_fixture(%{"priority" => 10})
      problem = CodeMySpec.Problems.from_credo(issue)
      assert problem.severity == :error
    end

    test "each Problem has severity mapped from Credo priority (>= 5: warning)" do
      issue = credo_issue_fixture(%{"priority" => 5})
      problem = CodeMySpec.Problems.from_credo(issue)
      assert problem.severity == :warning
    end

    test "each Problem has severity mapped from Credo priority (< 5: info)" do
      issue = credo_issue_fixture(%{"priority" => 2})
      problem = CodeMySpec.Problems.from_credo(issue)
      assert problem.severity == :info
    end

    test "each Problem has category from Credo category field" do
      issue = credo_issue_fixture(%{"category" => "consistency"})
      problem = CodeMySpec.Problems.from_credo(issue)
      assert problem.category == "consistency"
    end

    test "each Problem has rule from Credo check name" do
      issue = credo_issue_fixture(%{"check" => "Credo.Check.Consistency.TabsOrSpaces"})
      problem = CodeMySpec.Problems.from_credo(issue)
      assert problem.rule == "Credo.Check.Consistency.TabsOrSpaces"
    end
  end

  # ============================================================================
  # run/2 - Error Cases
  # ============================================================================

  describe "run/2 - error handling" do
    test "returns {:error, String.t()} when scope has no cwd" do
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)
      project = project_fixture(scope)
      scope = user_scope_fixture(user, account, project)

      assert {:error, error_message} = Credo.run(scope)
      assert is_binary(error_message)
    end

    test "handles missing project directory gracefully" do
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)
      project = project_fixture(scope)

      scope =
        user_scope_fixture(user, account, project) |> Map.put(:cwd, "/nonexistent/directory")

      use_cmd_cassette "static_analysis_credo_run_nonexistent", ignore: [[:opts, :cd]] do
        capture_log(fn ->
          assert {:error, error_message} = Credo.run(scope)
          assert is_binary(error_message)
        end)
      end
    end
  end

  # ============================================================================
  # run/2 - Options and Configuration
  # ============================================================================

  describe "run/2 - options" do
    @tag timeout: 120_000
    test "returns error when config_file doesn't exist", %{scope: scope} do
      use_cmd_cassette "static_analysis_credo_run_with_config", ignore: [[:opts, :cd]] do
        {:error, message} = Credo.run(scope, config_file: ".nonexistent.exs")
        assert message =~ "does not exist"
      end
    end
  end

  # ============================================================================
  # run/2 - Resource Management
  # ============================================================================

  describe "run/2 - temporary file cleanup" do
    test "cleans up temporary files even on errors" do
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)
      project = project_fixture(scope)
      scope = user_scope_fixture(user, account, project) |> Map.put(:cwd, "/nonexistent")

      temp_dir = System.tmp_dir!()
      before_files = list_temp_files(temp_dir, "credo_output")

      use_cmd_cassette "static_analysis_credo_run_nonexistent", ignore: [[:opts, :cd]] do
        capture_log(fn ->
          Credo.run(scope)
        end)
      end

      after_files = list_temp_files(temp_dir, "credo_output")
      assert length(after_files) <= length(before_files)
    end
  end

  # ============================================================================
  # Fixtures
  # ============================================================================

  defp credo_issue_fixture(attrs \\ %{}) do
    Enum.into(attrs, %{
      "priority" => 10,
      "category" => "readability",
      "check" => "Credo.Check.Readability.ModuleDoc",
      "message" => "Modules should have a @moduledoc tag.",
      "filename" => "lib/example.ex",
      "line_no" => 1,
      "column" => nil,
      "trigger" => "Example",
      "scope" => "Example"
    })
  end

  defp list_temp_files(temp_dir, prefix) do
    temp_dir |> File.ls() |> filter_by_prefix(prefix)
  end

  defp filter_by_prefix({:ok, files}, prefix),
    do: Enum.filter(files, &String.starts_with?(&1, prefix))

  defp filter_by_prefix({:error, _}, _prefix), do: []
end
