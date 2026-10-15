defmodule CodeMySpec.PromotionQueue.AHarnessStillRegisteringIsNotABuildFailureTest do
  @moduledoc """
  Issue a3b34f83: the queue intermittently failed a tick with "could not read
  main's HEAD: harness_not_registered" for the main copy, right after a
  promote restarts its harness and before it rejoins the channel -- and
  recovered on its own on a later tick. Nothing was lost, only delayed, but
  the tick treated it exactly like a genuine build failure (Credo/compiler/
  spex problems, a real conflict), which backs off for the long retry period
  -- the wrong signal for a registration window that clears itself in a tick
  or two.

  `could_not_build/2` now tells the two apart: a `harness_not_registered`
  reason for main's own HEAD read gets the short recheck wait instead of the
  long retry backoff a genuine build failure gets, and nothing is ejected --
  the candidate stays queued for the next tick either way.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.PromotionQueue
  alias CodeMySpec.PromotionQueue.Repository
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecTest.PromotionQueueHelpers

  setup do
    scope = full_scope_fixture()

    {:ok, main} = WorkingCopies.issue(scope, nil, label: "main", device: device_fixture(scope))
    # Main is the project's only checkout at this point, so report_root/2
    # designates it main on its own -- the same thing a promote's restart
    # would have just done to it.
    {:ok, main} = WorkingCopies.report_root(main, "/main")

    # Main's harness, not yet registered -- the exact window a3b34f83
    # reports: its channel has not rejoined since a promote restarted it, so
    # HarnessRegistry has nothing under its id, even though the copy itself
    # is of type :harness and genuinely exists.
    :ok =
      register_working_copy_environment(
        %{scope | active_working_copy_id: main.id},
        Environment.new(:harness, "/main", ref: %{"harness_id" => main.id})
      )

    {:ok, candidate} =
      WorkingCopies.issue(scope, nil, label: "a team", device: device_fixture(scope))

    {:ok, entry} =
      Repository.enqueue(%{
        project_id: scope.active_project_id,
        working_copy_id: candidate.id,
        commit: String.duplicate("a", 40),
        restart: false
      })

    on_exit(fn -> PromotionQueueHelpers.stop_worker(scope.active_project_id) end)

    %{scope: scope, entry: entry}
  end

  defp worker_pid(project_id) do
    [{pid, _}] = Registry.lookup(CodeMySpec.PromotionQueue.Registry, project_id)
    pid
  end

  test "a build tick against an unregistered main harness gets the short recheck, not the " <>
         "long build-failure backoff",
       ctx do
    :ok = PromotionQueue.ensure_worker(ctx.scope)
    # Long enough for the worker's own init -> :next -> build -> could_not_build
    # chain to run and land in :idle with its retry timer armed.
    Process.sleep(300)

    pid = worker_pid(ctx.scope.active_project_id)
    state = :sys.get_state(pid)

    assert state.phase == :idle,
           "the tick did not settle back to idle after main's HEAD could not be read"

    assert is_reference(state.timer), "no retry timer was armed after the failed tick"

    remaining = Process.read_timer(state.timer)
    assert is_integer(remaining), "the retry timer had already fired or did not exist"

    assert remaining < 200_000,
           "a harness-registration gap waited close to the 300s build-failure backoff " <>
             "instead of the 120s recheck. remaining: #{remaining}ms"

    assert [requeued] = Repository.queued(ctx.scope.active_project_id, 10)
    assert requeued.id == ctx.entry.id

    assert requeued.status == :queued,
           "the candidate was ejected instead of simply waiting for main's harness to rejoin"
  end
end
