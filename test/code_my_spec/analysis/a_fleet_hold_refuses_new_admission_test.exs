defmodule CodeMySpec.Analysis.AFleetHoldRefusesNewAdmissionTest do
  @moduledoc """
  783f3709: a hold delivered only as a queued instruction offer never reached
  an agent mid-run. `start_run/4` (`start_analysis`) and `await_run/4` (the
  agent's own `mix test`/`mix spex` rewrite) are the two admission points
  every analyzer request passes through, so the hold is checked there instead
  of only at a turn boundary.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.FleetHolds
  alias CodeMySpec.Analysis.RunsRepository

  setup do
    %{scope: full_scope_fixture()}
  end

  test "start_run refuses to admit while a hold stands, naming it", %{scope: scope} do
    {:ok, hold} = FleetHolds.place(scope, "load 40, five agents running tests")

    assert {:error, {:held, ^hold}} = Analysis.start_run(scope, "compiler", [])
    assert RunsRepository.latest_full_runs(scope) == %{}
  end

  test "start_run admits normally once the hold lifts", %{scope: scope} do
    {:ok, _hold} = FleetHolds.place(scope, "load 40")
    {:ok, _} = FleetHolds.lift(scope)

    assert {:ok, _, _run_id} = Analysis.start_run(scope, "compiler", [])
  end

  test "start_run admits normally when nothing is held", %{scope: scope} do
    assert {:ok, _, _run_id} = Analysis.start_run(scope, "compiler", [])
  end

  test "await_run refuses while a hold stands, naming it", %{scope: scope} do
    {:ok, hold} = FleetHolds.place(scope, "load 40, five agents running tests")

    assert {:error, {:held, ^hold}} = Analysis.await_run(scope, "compiler", [])
    assert RunsRepository.latest_full_runs(scope) == %{}
  end

  test "await_run proceeds once the hold lifts", %{scope: scope} do
    {:ok, _hold} = FleetHolds.place(scope, "load 40")
    {:ok, _} = FleetHolds.lift(scope)

    # Whether the compiler itself can run in this sandboxed environment is not
    # this test's concern -- only that the hold no longer refuses admission.
    refute match?({:error, {:held, _}}, Analysis.await_run(scope, "compiler", []))
  end

  # A hold placed after admission must never reach back into a run already
  # open -- only the two admission points above check it.
  test "a run already admitted before the hold is placed is unaffected", %{scope: scope} do
    {:ok, run} = RunsRepository.start_run(scope, %{source: "exunit", kind: :full})
    {:ok, _hold} = FleetHolds.place(scope, "load 40")

    assert {:ok, _} = RunsRepository.finish_run(run, :completed, %{exit_status: 0})
    assert Analysis.answered?(scope, "exunit")
  end
end
