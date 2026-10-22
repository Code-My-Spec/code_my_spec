defmodule CodeMySpec.Analysis.ARunIsCancelledWhereItRunsTest do
  @moduledoc """
  Story 1142: a run is cancelled on the copy that runs it, whichever copy the
  person cancelling it is on. QA's browser was on another copy than the agent
  whose run it cancelled, and Cancel did nothing (issue 3011abeb).
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Analysis.RunsRepository
  alias CodeMySpec.WorkingCopies

  setup do
    scope = full_scope_fixture()

    {:ok, running_copy} =
      WorkingCopies.issue(scope, nil, label: "the run's checkout", device: device_fixture(scope))

    running_on = %{scope | active_working_copy_id: running_copy.id}
    :ok = HarnessRegistry.register_executor(running_copy.id)
    {:ok, run} = RunsRepository.start_run(running_on, %{source: "exunit", kind: :full})

    %{scope: scope, run: run}
  end

  test "from another copy, the run's own harness is told to cancel it", ctx do
    assert :ok = Analysis.cancel_run(ctx.scope, ctx.run.id)

    run_id = ctx.run.id
    assert_receive {:cancel_run, ^run_id}
  end

  test "a run that already ended is not running", ctx do
    {:ok, _} = RunsRepository.finish_run(ctx.run, :completed, %{})

    assert {:error, :not_running} = Analysis.cancel_run(ctx.scope, ctx.run.id)
    refute_received {:cancel_run, _}
  end
end
