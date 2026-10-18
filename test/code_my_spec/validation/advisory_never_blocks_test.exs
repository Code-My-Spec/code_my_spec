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

  describe "an advisory credo finding" do
    setup %{scope: scope} do
      Configurations.get_or_create(scope)
      {:ok, _} = Configurations.update(scope, %{credo: :block_all})
      problem_fixture(scope, %{source: "credo", severity: :info, file_path: @path})
      fresh_analysis_runs_fixture(scope)
      :ok
    end

    test "does not block promotion by default", %{scope: scope} do
      assert Promotion.blocking_problems(scope) == []
    end
  end
end
