defmodule CodeMySpec.Analysis.StuckWorkTest do
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.Analysis.StuckWork
  alias CodeMySpec.Analysis.Tools.GetAnalysisLive
  alias CodeMySpec.Repo

  setup do
    %{scope: full_scope_fixture()}
  end

  test "duration and silence have separate thresholds" do
    refute StuckWork.stuck?(120, 30, 60, 2, 300)
    assert StuckWork.stuck?(121, 30, 60, 2, 300)
    assert StuckWork.stuck?(30, 300, 60, 2, 300)
    refute StuckWork.stuck?(30, 30, nil, 2, 300)
    assert StuckWork.percentile([10, 20, 30, 40, 50], 90) == 50
  end

  test "snapshot reconciles the ledger and reports only overdue open runs", %{scope: scope} do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    finished_at = DateTime.add(now, -100, :second)
    finished = insert_run(scope, :completed, DateTime.add(finished_at, -60, :second), finished_at)
    overdue = insert_run(scope, :running, DateTime.add(now, -121, :second))
    _recent = insert_run(scope, :running, DateTime.add(now, -20, :second))

    report = StuckWork.snapshot(scope, now: now, silence_minutes: 60)

    assert report.analysis == %{started: 3, finished: 1, open: 2, oldest_open_minutes: 2}
    assert report.promotion == %{started: 0, finished: 0, open: 0, oldest_open_minutes: nil}
    assert [%{run_id: run_id, age_seconds: 121, status: "stuck"}] = report.runs
    assert run_id == overdue.id
    assert finished.id != run_id
  end

  test "an orphaned run is presented as abandoned with the disconnect reason", %{scope: scope} do
    run =
      insert_run(
        scope,
        :failed,
        DateTime.add(DateTime.utc_now(), -60, :second),
        DateTime.utc_now()
      )

    run = run |> Run.changeset(%{orphaned: true}) |> Repo.update!()
    live = GetAnalysisLive.describe(run, nil, DateTime.utc_now())
    assert live.status == "abandoned"
    assert live.reason =~ "disconnect"
  end

  defp insert_run(scope, status, started_at, finished_at \\ nil) do
    %Run{}
    |> Run.changeset(%{
      source: "exunit",
      kind: :full,
      status: status,
      project_id: scope.active_project_id,
      working_copy_id: scope.active_working_copy_id,
      started_at: started_at,
      finished_at: finished_at
    })
    |> Repo.insert!()
  end
end
