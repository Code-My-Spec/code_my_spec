defmodule CodeMySpec.PromotionQueue.AHarnessStillRegisteringIsNotABuildFailureTest do
  @moduledoc """
  Issue a3b34f83: the queue intermittently failed a tick with "could not read
  main's HEAD: harness_not_registered" for the main copy, right after a
  promote restarts its harness and before it rejoins the channel. The tick
  treated it like a build failure and retried on a timer.

  Main being unreachable is nobody's candidate. The queue reads main before it
  takes one, so the candidate is never taken: it stays queued, nothing is
  ejected, and no timer is armed. Main's harness rejoining is what wakes the
  queue (`PromotionQueue.copy_joined/2`).
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

  test "an unreachable main leaves the candidate queued and untaken, with no retry timer",
       ctx do
    :ok = PromotionQueue.ensure_worker(ctx.scope)
    # `init/1` sends itself `:next` before this call reaches it.
    state = :sys.get_state(worker_pid(ctx.scope.active_project_id))

    assert state.phase == :idle
    assert state.timer == nil, "the queue retried on a timer instead of waiting for a join"

    assert [waiting] = Repository.queued(ctx.scope.active_project_id, 10)
    assert waiting.id == ctx.entry.id

    assert waiting.status == :queued,
           "the candidate was taken or ejected over main being unreachable"
  end
end
