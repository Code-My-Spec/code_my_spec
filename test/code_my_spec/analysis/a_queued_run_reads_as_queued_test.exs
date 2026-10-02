defmodule CodeMySpec.Analysis.AQueuedRunReadsAsQueuedTest do
  @moduledoc """
  A run is `:running` from the moment it is requested, so one waiting behind
  others for a machine slot read exactly like a hung one (bf627680, run
  54245). `began_at` is stamped when the harness reports the analyzer started.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.AnalysisFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.Run

  setup do
    scope = full_scope_fixture()
    %{scope: scope, run: analysis_run_fixture(scope, %{source: "compiler", kind: :full})}
  end

  test "a requested run is queued until it begins", %{run: run} do
    assert run.began_at == nil
    assert Run.queued?(run)
  end

  test "the harness reporting its start stamps when it began", %{scope: scope, run: run} do
    assert {:ok, started} =
             Analysis.record_remote_start(scope, %{
               "run_id" => run.id,
               "start_commit" => String.duplicate("a", 40),
               "start_tree_dirty" => false
             })

    assert %DateTime{} = started.began_at
    refute Run.queued?(started)
  end
end
