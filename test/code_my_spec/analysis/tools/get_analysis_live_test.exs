defmodule CodeMySpec.Analysis.Tools.GetAnalysisLiveTest do
  @moduledoc """
  An agent can see a run while it runs. `get_analysis_output` reads the
  ledger's retained output, which is empty until the run ends: run 62990,
  mid-run, answered `output_available: false` and nothing else, so an agent
  could not tell progress from a stall (issue 96d02161).
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.AnalysisFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Analysis.LiveRuns
  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.Analysis.Tools.GetAnalysisLive
  alias CodeMySpec.ToolLibrary

  setup do
    scope = full_scope_fixture()
    %{scope: scope, run: analysis_run_fixture(scope, %{source: "exunit", kind: :partial})}
  end

  defp live(params, scope) do
    assert {:ok, text} =
             ToolLibrary.run("get_analysis_live", params, %{current_scope: scope, scope: scope})

    Jason.decode!(text)
  end

  test "a run that has reported nothing says so", %{scope: scope, run: run} do
    assert %{"run_id" => id, "live" => "not_retained"} = live(%{run_id: run.id}, scope)
    assert id == run.id

    LiveRuns.fold(run.id, %{"event" => "unknown_to_the_fold"})

    assert %{"live" => "streaming", "tests" => %{"reported" => 0}} =
             live(%{run_id: run.id}, scope)
  end

  test "mid-run: the files it is in, its counts, its failures and its freshness", %{
    scope: scope,
    run: run
  } do
    LiveRuns.fold(run.id, %{"event" => "file_started", "file" => "test/a_test.exs"})
    LiveRuns.fold(run.id, %{"event" => "test", "name" => "works", "state" => "passed"})

    LiveRuns.fold(run.id, %{
      "event" => "test",
      "name" => "breaks",
      "file" => "test/a_test.exs",
      "line" => 12,
      "state" => "failed",
      "message" => "Assertion with == failed"
    })

    assert %{
             "live" => "streaming",
             "running_files" => ["test/a_test.exs"],
             "tests" => %{"reported" => 2, "passed" => 1, "failed" => 1, "skipped" => 0},
             "failures" => [%{"name" => "breaks", "line" => 12, "message" => message}],
             "seconds_since_event" => seconds
           } = live(%{source: "exunit"}, scope)

    assert message =~ "Assertion"
    assert seconds in 0..5
  end

  # 90492d2d: queued and waiting-on-a-reachable-harness both read as the same
  # bare "queued" forever, with no way to tell a stalled wait from ordinary load.
  test "a queued run with no reachable harness says so, not just that it waits", %{
    scope: scope,
    run: run
  } do
    assert %{"status" => "queued", "harness_connected" => false, "queued_seconds" => seconds} =
             live(%{run_id: run.id}, scope)

    assert seconds >= 0
  end

  test "a queued run with a connected harness reports it", %{scope: scope, run: run} do
    HarnessRegistry.register_executor(scope.active_working_copy_id, "i", "/tmp/root")

    assert %{"harness_connected" => true} = live(%{run_id: run.id}, scope)
  end

  test "a run that reported its end is finished", %{scope: scope, run: run} do
    LiveRuns.fold(run.id, %{"event" => "file_started", "file" => "test/a_test.exs"})
    LiveRuns.fold(run.id, %{"event" => "file_finished", "file" => "test/a_test.exs"})
    LiveRuns.fold(run.id, %{"event" => "finished", "files" => 1})

    assert %{"live" => "finished", "running_files" => [], "totals" => %{"files" => 1}} =
             live(%{run_id: run.id}, scope)
  end

  test "a run with no events yet is told apart from one streaming" do
    now = DateTime.utc_now()
    run = %Run{id: 1, source: "spex", status: :running, began_at: now}

    live = %{
      running_files: [],
      tests: [],
      findings: [],
      totals: nil,
      finished?: false,
      last_event_at: nil
    }

    assert %{live: "no_events", status: "running", seconds_since_event: nil} =
             GetAnalysisLive.describe(run, live, now)
  end
end
