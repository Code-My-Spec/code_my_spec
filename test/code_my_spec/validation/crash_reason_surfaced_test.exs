defmodule CodeMySpec.Validation.CrashReasonSurfacedTest do
  @moduledoc """
  An analyzer that could not run has a reason, and the agent has to see it.

  `639d0fc1`. An un-onboarded working copy made credo crash before it started,
  104 times across two checkouts, with the cause recorded on every run:

      credo crashed: /Users/…/intake-on-home has no recorded test partition,
      so it has not been onboarded. Run: mix harness.onboard

  What the stop hook served instead was the previous run's findings, correctly
  labelled stale, on a file the agent had already fixed, committed and verified
  clean — the same finding three times, still citing a line number from before
  the edit that shifted it. The offered remedy was "stop again and let a rerun
  replace these", and the rerun crashed the same way, so nothing the agent
  could edit was ever measured.

  The reason existed the whole time, one process away, in a column nothing read
  back. `Reconciler.fail/2` writes it to `stats["error"]`; `failure_reason/1`
  read only `output`, which is what the *tool* printed — and a tool that
  crashed before starting printed nothing. Two failure shapes, two columns, one
  of them surfaced.

  It is the second analyzer that week to fail an unmet precondition and present
  it as stale findings; spex did the same through the migration guard
  (`6f89b278`). So the assertions are about the column, not the incident.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis.{Reconciler, RunsRepository}
  alias CodeMySpec.Validation

  @crash "credo crashed: /Users/x/intake-on-home has no recorded test partition, " <>
           "so it has not been onboarded.\nRun: mix harness.onboard"

  setup do
    %{scope: full_scope_fixture()}
  end

  defp failed_run(scope, source, reason) do
    {:ok, run} =
      RunsRepository.start_run(scope, %{source: source, kind: :full, args: %{"args" => []}})

    {:ok, _} = Reconciler.fail(run, reason)
    :ok
  end

  test "a crash before the tool ran is reported, not swallowed", %{scope: scope} do
    failed_run(scope, "credo", @crash)

    reasons = Validation.run_failures(scope, ["credo"])

    assert reasons["credo"] =~ "has not been onboarded",
           "the cause was recorded on the run and nothing read it back, so the " <>
             "agent was handed stale findings and told to stop again — which " <>
             "re-entered the same crash"

    assert reasons["credo"] =~ "mix harness.onboard",
           "the remedy travels with the reason; without it the message names a " <>
             "state but not a way out"
  end

  test "a source that ran cleanly reports nothing", %{scope: scope} do
    assert Validation.run_failures(scope, ["credo"]) == %{}
  end

  # The pre-existing path, which read `output` — the tool ran and printed why it
  # failed. Both shapes have to work; fixing the second must not lose the first.
  test "a tool that ran and printed a failure is still reported", %{scope: scope} do
    {:ok, run} =
      RunsRepository.start_run(scope, %{source: "exunit", kind: :full, args: %{"args" => []}})

    {:ok, _} =
      RunsRepository.finish_run(run, :failed, %{output: "** (Mix) Could not find a Mix.Project"})

    assert Validation.run_failures(scope, ["exunit"])["exunit"] =~ "Could not find a Mix.Project"
  end

  # Six lines and 600 bytes. An analyzer that dies mid-suite can write a great
  # deal, and this rides in a stop response with a byte cap.
  test "a long reason is truncated rather than filling the response", %{scope: scope} do
    failed_run(scope, "spex", Enum.map_join(1..50, "\n", &"line #{&1}"))

    reason = Validation.run_failures(scope, ["spex"])["spex"]

    assert reason =~ "line 1"
    refute reason =~ "line 20"
  end
end
