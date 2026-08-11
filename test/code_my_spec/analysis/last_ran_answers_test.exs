defmodule CodeMySpec.Analysis.LastRanAnswersTest do
  @moduledoc """
  The age a stale source reports is the age of the answer, not of the attempt.

  Staleness comes from `latest_completed_run/2` — "the latest run that
  *answered*, not the latest run", as `fresh?/2` puts it, because a failure
  cannot make a good result stale. The age beside it came from
  `latest_full_runs/1`, which includes `:failed`. Two different runs wearing one
  label, and the failure is usually the newer of the two.

  So a source whose last real answer is an hour old reports "last ran 2m ago"
  on the strength of a run that produced nothing, and every piece of advice
  keyed to that age inverts: mid-cycle instead of wedged, wait instead of
  escalate.

  Measured on the live ledger while writing this — spex last completed at
  03:59:05 and last failed at 04:02:52, so the reported age was of the failure
  and understated the real one by nearly four minutes. `83cde34f` read the same
  shape as another working copy's run leaking in; it needs no second checkout.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis.RunsRepository
  alias CodeMySpec.Harnesses
  alias CodeMySpec.Validation

  setup do
    scope = full_scope_fixture()
    {:ok, harness} = Harnesses.issue(scope, nil, label: "a working copy")
    %{scope: %{scope | active_harness_id: harness.id}}
  end

  defp finished_run(scope, source, status, ago_seconds) do
    at = DateTime.add(DateTime.utc_now(), -ago_seconds, :second)

    {:ok, run} =
      RunsRepository.start_run(scope, %{
        source: source,
        kind: :full,
        started_at: DateTime.add(at, -30, :second)
      })

    {:ok, run} = RunsRepository.finish_run(run, status, %{finished_at: at})
    run
  end

  test "a newer failure does not become the reported age", %{scope: scope} do
    finished_run(scope, "spex", :completed, 3_600)
    finished_run(scope, "spex", :failed, 120)

    {last_ran, _duration, _overtaken} = Validation.run_timing(scope, ["spex"])

    age = DateTime.diff(DateTime.utc_now(), Map.fetch!(last_ran, "spex"), :second)

    assert age > 3_000,
           "the answer is an hour old; reporting the 2-minute failure as the age " <>
             "turns a wedged analyzer into one that looks mid-cycle"
  end

  test "the completed run's own age is reported when it is the newest", %{scope: scope} do
    finished_run(scope, "spex", :failed, 3_600)
    finished_run(scope, "spex", :completed, 120)

    {last_ran, _duration, _overtaken} = Validation.run_timing(scope, ["spex"])
    age = DateTime.diff(DateTime.utc_now(), Map.fetch!(last_ran, "spex"), :second)

    assert age < 600
  end

  test "duration comes from the same run as the age", %{scope: scope} do
    # Not merely tidiness: the overtaken-on-arrival branch compares them, so a
    # duration read off one run and an age off another can make a slow source
    # look overtaken when it is simply old, or the reverse.
    finished_run(scope, "spex", :completed, 3_600)
    finished_run(scope, "spex", :failed, 120)

    {_last_ran, duration, _overtaken} = Validation.run_timing(scope, ["spex"])

    assert Map.fetch!(duration, "spex") == 30
  end

  test "a source that has never completed reports no age", %{scope: scope} do
    finished_run(scope, "spex", :failed, 120)

    {last_ran, _duration, _overtaken} = Validation.run_timing(scope, ["spex"])

    assert Map.fetch!(last_ran, "spex") == nil,
           "never answered is a different condition from answered a while ago, " <>
             "and the footer already says so — it must not be handed a failure's " <>
             "timestamp and call it an answer"
  end
end
