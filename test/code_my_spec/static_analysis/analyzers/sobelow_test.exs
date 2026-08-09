defmodule CodeMySpec.StaticAnalysis.Analyzers.SobelowTest do
  use CodeMySpecTest.DataCase, async: false

  use ExCliVcr
  import CodeMySpec.{UsersFixtures, AccountsFixtures, ProjectsFixtures}
  import ExUnit.CaptureLog

  alias CodeMySpec.StaticAnalysis.Analyzers.Sobelow
  alias CodeMySpec.Problems.Problem

  @test_repo_url "https://github.com/Code-My-Spec/test_phoenix_project.git"

  setup do
    user = user_fixture()
    account = account_with_owner_fixture(user)
    scope = user_scope_fixture(user, account)
    project = project_fixture(scope, %{module_name: "TestPhoenixProject"})
    scope = user_scope_fixture(user, account, project)

    # Clone from pool
    {:ok, project_dir} = CodeMySpec.Support.TestAdapter.clone(scope, @test_repo_url)

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
  # name/0
  # ============================================================================

  describe "name/0" do
    test "returns \"sobelow\"" do
      assert Sobelow.name() == "sobelow"
    end

    test "returns consistent value across calls" do
      first_call = Sobelow.name()
      second_call = Sobelow.name()

      assert first_call == second_call
      assert first_call == "sobelow"
    end
  end

  # ============================================================================
  # available?/1
  # ============================================================================

  describe "available?/1" do
    test "returns true when sobelow deps directory exists", %{
      scope: scope,
      project_dir: project_dir
    } do
      # Create deps/sobelow directory to simulate sobelow being installed
      sobelow_deps_path = Path.join(project_dir, "deps/sobelow")
      File.mkdir_p!(sobelow_deps_path)

      assert Sobelow.available?(scope) == true
    end

    test "returns false when sobelow deps directory missing", %{
      scope: scope,
      project_dir: project_dir
    } do
      # Remove deps/sobelow to simulate it being missing
      sobelow_deps_path = Path.join(project_dir, "deps/sobelow")
      File.rm_rf!(sobelow_deps_path)

      assert Sobelow.available?(scope) == false
    end

    test "returns false when cwd path is invalid" do
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)
      project = project_fixture(scope)

      scope =
        user_scope_fixture(user, account, project) |> Map.put(:cwd, "/nonexistent/invalid/path")

      assert Sobelow.available?(scope) == false
    end

    test "returns false when mix.exs is missing" do
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)

      project_dir =
        System.tmp_dir!() |> Path.join("sobelow_no_mix_#{System.unique_integer([:positive])}")

      File.mkdir_p!(project_dir)

      project = project_fixture(scope)
      scope = user_scope_fixture(user, account, project) |> Map.put(:cwd, project_dir)

      result = Sobelow.available?(scope)
      File.rm_rf!(project_dir)

      assert result == false
    end

    test "does not raise exceptions" do
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)
      project = project_fixture(scope)
      scope = user_scope_fixture(user, account, project) |> Map.put(:cwd, "/nonexistent")

      result = Sobelow.available?(scope)
      assert is_boolean(result)
    end

    test "executes quickly without blocking", %{scope: scope} do
      {time_microseconds, _result} = :timer.tc(fn -> Sobelow.available?(scope) end)
      # Should complete in under 100ms (just file checks)
      assert time_microseconds < 100_000
    end
  end

  # ============================================================================
  # run/2 - Happy Path
  # ============================================================================

  describe "run/2" do
    @tag timeout: 120_000
    test "returns {:ok, list(Problem.t())} when sobelow runs", %{scope: scope} do
      use_cmd_cassette "static_analysis_sobelow_run", ignore: [[:opts, :cd]] do
        {:ok, problems} = Sobelow.run(scope, [])
        assert not Enum.empty?(problems)

        assert is_list(problems)
        assert not Enum.empty?(problems)

        Enum.each(problems, fn problem ->
          assert %Problem{} = problem
        end)
      end
    end

    @tag timeout: 120_000
    test "sets source to \"sobelow\" for all problems", %{scope: scope} do
      use_cmd_cassette "static_analysis_sobelow_run", ignore: [[:opts, :cd]] do
        {:ok, problems} = Sobelow.run(scope, [])
        assert not Enum.empty?(problems)

        Enum.each(problems, fn problem ->
          assert problem.source == "sobelow"
        end)
      end
    end

    @tag timeout: 120_000
    test "sets source_type to :static_analysis for all problems", %{scope: scope} do
      use_cmd_cassette "static_analysis_sobelow_run", ignore: [[:opts, :cd]] do
        {:ok, problems} = Sobelow.run(scope, [])
        assert not Enum.empty?(problems)

        Enum.each(problems, fn problem ->
          assert problem.source_type == :static_analysis
        end)
      end
    end

    @tag timeout: 120_000
    test "sets category to \"security\" for all problems", %{scope: scope} do
      use_cmd_cassette "static_analysis_sobelow_run", ignore: [[:opts, :cd]] do
        {:ok, problems} = Sobelow.run(scope, [])
        assert not Enum.empty?(problems)

        Enum.each(problems, fn problem ->
          assert problem.category == "security"
        end)
      end
    end

    test "sets severity to :error for high severity findings" do
      severity = map_sobelow_severity("high")
      assert severity == :error
    end

    test "sets severity to :warning for medium severity findings" do
      severity = map_sobelow_severity("medium")
      assert severity == :warning
    end

    test "sets severity to :info for low severity findings" do
      severity = map_sobelow_severity("low")
      assert severity == :info
    end
  end

  # ============================================================================
  # run/2 - Error Cases
  # ============================================================================

  describe "run/2 - error handling" do
    test "returns {:error, String.t()} when cwd path is invalid" do
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)
      project = project_fixture(scope)

      scope =
        user_scope_fixture(user, account, project) |> Map.put(:cwd, "/nonexistent/invalid/path")

      use_cmd_cassette "static_analysis_sobelow_run_nonexistent", ignore: [[:opts, :cd]] do
        capture_log(fn ->
          result = Sobelow.run(scope, [])
          assert match?({:error, _}, result)
        end)
      end
    end

    test "cleans up temporary file even when errors occur" do
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)
      project = project_fixture(scope)
      scope = user_scope_fixture(user, account, project) |> Map.put(:cwd, "/nonexistent")

      temp_files_before = count_temp_files()

      use_cmd_cassette "static_analysis_sobelow_run_nonexistent", ignore: [[:opts, :cd]] do
        capture_log(fn ->
          Sobelow.run(scope, [])
        end)
      end

      Process.sleep(100)

      temp_files_after = count_temp_files()

      # Should not accumulate temp files
      assert temp_files_after <= temp_files_before + 1
    end
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp map_sobelow_severity("high"), do: :error
  defp map_sobelow_severity("medium"), do: :warning
  defp map_sobelow_severity("low"), do: :info
  defp map_sobelow_severity(_), do: :warning

  # Sobelow's own temp files, not everything in the directory.
  #
  # `create_temp_file/0` writes `sobelow_output_<id>.json` into
  # `System.tmp_dir!()`, which is shared. Counting the whole directory made
  # this an assertion about what else the machine was doing: the harness puts
  # `spex_output_*.jsonl`, `test_output_*.json` and `cms_harness_*` in there,
  # and a spex sweep runs for two to three minutes at a time. Anything landing
  # during the 100ms sleep pushed the count past `before + 1` and failed a
  # cleanup that had in fact happened.
  defp count_temp_files do
    count_listed(File.ls(System.tmp_dir!()))
  end

  defp count_listed({:ok, files}),
    do: Enum.count(files, &String.starts_with?(&1, "sobelow_output_"))

  defp count_listed({:error, _}), do: 0
end
