defmodule CodeMySpec.Analysis.RunCommitColumnsTest do
  @moduledoc """
  `analysis_runs` records the commit a run started on, whether the tree was
  clean then, and the commit it finished on. Nullable with no default: a run
  nobody reported a commit for has none.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.AnalysisFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.Repo

  test "a run nobody reported a commit for has none" do
    run = full_scope_fixture() |> analysis_run_fixture()

    assert %Run{start_commit: nil, start_tree_dirty: nil, completed_commit: nil} =
             Repo.get!(Run, run.id)
  end
end
