defmodule CodeMySpec.Validation.AdvisoryNeverBlocksTest do
  @moduledoc """
  b5fa5856: two low-priority ex_slop findings passed a promote and blocked the
  next copy's task evaluation, because the two paths had different rules.
  John, 2026-10-04: advisory never blocks, and task evaluation judges the whole
  copy as promotion does — both project settings.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.{AnalysisFixtures, ProblemsFixtures, UsersFixtures}

  alias CodeMySpec.Configurations
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Promotion
  alias CodeMySpec.Validation

  @path "lib/my_app/accounts.ex"

  setup do
    tmp = CodeMySpec.TempFile.owned_dir("advisory_never_blocks")
    environment = Environment.new(:local, tmp)
    scope = put_fixture_environment(%{full_scope_fixture() | cwd: tmp}, environment)
    :ok = register_working_copy_environment(scope, environment)

    File.mkdir_p!(Path.join(tmp, "lib/my_app"))
    File.write!(Path.join(tmp, @path), "defmodule MyApp.Accounts do\nend\n")
    {:ok, _} = FileSync.sync(scope, base_dir: tmp)

    %{scope: scope}
  end

  test "a credo warning in a file nobody touched this turn blocks, by default", %{scope: scope} do
    problem_fixture(scope, %{source: "credo", severity: :warning, file_path: @path})
    fresh_analysis_runs_fixture(scope)

    assert {:error, _reason, _key} = Validation.validate_stop(scope, nil),
           "task evaluation judged only changed files, so a finding promotion " <>
             "would refuse was let through"
  end

  describe "an advisory credo finding" do
    setup %{scope: scope} do
      Configurations.get_or_create(scope)
      {:ok, _} = Configurations.update(scope, %{credo: :block_all})
      problem_fixture(scope, %{source: "credo", severity: :info, file_path: @path})
      fresh_analysis_runs_fixture(scope)
      :ok
    end

    test "does not block task evaluation by default", %{scope: scope} do
      assert {:ok, _} = Validation.validate_stop(scope, nil)
    end

    test "does not block promotion by default", %{scope: scope} do
      assert Promotion.blocking_problems(scope) == []
    end

    test "blocks both when the project says advisory findings block", %{scope: scope} do
      {:ok, _} = Configurations.update(scope, %{advisory_findings: :block})

      assert {:error, _reason, _key} = Validation.validate_stop(scope, nil)
      assert [%{severity: :info}] = Promotion.blocking_problems(scope)
    end
  end
end
