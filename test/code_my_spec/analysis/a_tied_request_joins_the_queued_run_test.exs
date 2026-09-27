defmodule CodeMySpec.Analysis.ATiedRequestJoinsTheQueuedRunTest do
  @moduledoc """
  A request the harness would tie onto its queued run does not open a row.

  `75acdb84`: six compiler rows sat `:running` on one working copy, none
  executing. The harness holds at most two entries per source — the one running
  and the one queued — and ties every further request onto the queued one, so
  the rows past the second were waiters reading as runs.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.{Run, RunsRepository}

  # This process stands in for the harness channel, so the sweep dispatches
  # remotely and every `{:run_analysis, _}` lands in the mailbox.
  setup do
    scope = full_scope_fixture()

    {:ok, _} =
      Registry.register(
        CodeMySpec.Analysis.HarnessRegistry,
        to_string(scope.active_working_copy_id),
        :test
      )

    %{scope: scope}
  end

  defp open_run(scope, source, kind \\ :full) do
    {:ok, run} =
      RunsRepository.start_run(scope, %{source: source, kind: kind, args: %{"args" => []}})

    run
  end

  defp running_ids(scope, source) do
    Repo.all(
      from r in Run,
        where:
          r.project_id == ^scope.active_project_id and r.source == ^source and
            r.status == :running,
        select: r.id
    )
  end

  test "with two full runs open, a third request joins the newer one", %{scope: scope} do
    _executing = open_run(scope, "credo")
    queued = open_run(scope, "credo")

    Analysis.ensure_stale_runs(scope, ["credo"])

    assert Enum.sort(running_ids(scope, "credo")) |> length() == 2,
           "a request the harness ties onto its queued entry opened a row of its own"

    queued_id = queued.id
    assert_received {:run_analysis, [%{"run_id" => ^queued_id, "source" => "credo"}]}
  end

  test "with one full run open, a request still opens the next one", %{scope: scope} do
    first = open_run(scope, "credo")

    Analysis.ensure_stale_runs(scope, ["credo"])

    assert [_next] = running_ids(scope, "credo") -- [first.id],
           "a source merely running needs its next run queued (cc1016a8)"
  end

  test "partial runs are not joined onto", %{scope: scope} do
    open_run(scope, "credo", :partial)
    open_run(scope, "credo", :partial)

    Analysis.ensure_stale_runs(scope, ["credo"])

    assert length(running_ids(scope, "credo")) == 3
  end
end
