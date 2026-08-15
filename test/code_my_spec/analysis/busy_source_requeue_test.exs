defmodule CodeMySpec.Analysis.BusySourceRequeueTest do
  @moduledoc """
  A sweep that plans a source already running must still reach the harness.

  `cc1016a8`. `dispatch_remote/3` dropped the request when the source appeared
  in `running_sources/1`, on single-flight reasoning — two `mix test` processes
  in one `_build` corrupt it. The premise is right; the conclusion confused "do
  not run two at once" with "forget that a second was wanted".

  Measured on `phx-new-generator`: a spex run started at 00:30:24, a commit
  edited a spex file at 00:30:43, the 00:31:25 sweep planned spex and the
  request was dropped, and the run finishing at 00:33:57 answered about the
  pre-commit tree. Nothing re-queued it, so `analysis/wait` reported "ok" with
  spex stale and the queue idle — accurate and useless — while `FixBddSpecs`,
  which gates on `Analysis.fresh?(scope, "spex")`, told the agent to wait and
  re-evaluate. Three loop ticks before somebody ran the analyzer by hand.

  The harness never needed the protection. `AnalysisServer` runs one task at a
  time by construction, and its `accept/2` refuses only a source already
  *queued* — a second *pending* run would deliver the same answer twice, while
  a source merely *running* is accepted and queued behind itself. That is the
  case a post-commit sweep is.

  What this asserts is that a **second run row is opened** while the first is
  still running, because that is the observable the drop removed — the request
  never reached `start_run/2`.

  Asserting the *planning* layer would not have worked, and I wrote that
  version first: `plan_runs/4` always returned the source as stale, with the bug
  present and without it. Planning was never broken. Verified by re-introducing
  the guard on the dispatch path and watching this file stay green — the test
  had to move down a layer to have any grip.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.{Run, RunsRepository}

  setup do
    scope = full_scope_fixture()
    %{scope: scope}
  end

  defp open_run(scope, source) do
    {:ok, run} =
      RunsRepository.start_run(scope, %{source: source, kind: :full, args: %{"args" => []}})

    run
  end

  describe "a source already running" do
    test "is reported in flight", %{scope: scope} do
      open_run(scope, "spex")

      assert "spex" in RunsRepository.running_sources(scope),
             "the precondition this test is about — without it the assertions below " <>
               "would pass for the wrong reason"
    end

    # The regression itself, asserted on rows rather than on the plan.
    test "gets a second run row from a sweep", %{scope: scope} do
      first = open_run(scope, "spex")

      Analysis.ensure_stale_runs(scope, ["spex"], [])

      others = spex_runs(scope) -- [first.id]

      assert others != [],
             "the sweep opened no run for a source that was already running, so the " <>
               "edit that triggered it is never analysed — the source stays stale " <>
               "with nothing queued, and analysis/wait reports idle while it does"
    end

    test "a second source is unaffected by the first being busy", %{scope: scope} do
      open_run(scope, "spex")

      %{enqueued: enqueued} = Analysis.ensure_stale_runs(scope, ["spex", "credo"], [])

      assert "spex" in enqueued
      assert "credo" in enqueued
    end
  end

  defp spex_runs(scope) do
    Repo.all(
      from r in Run,
        where: r.project_id == ^scope.active_project_id and r.source == "spex",
        select: r.id
    )
  end

  # `only_failed: true` is the quiet-stop path and has its own rules — it
  # re-enqueues what broke, and a source that has never completed counts as
  # stale. A running row is not a completed one, so it stays eligible.
  test "a quiet stop still opens a run for a running source", %{scope: scope} do
    first = open_run(scope, "spex")

    Analysis.ensure_stale_runs(scope, ["spex"], only_failed: true)

    assert spex_runs(scope) -- [first.id] != []
  end
end
