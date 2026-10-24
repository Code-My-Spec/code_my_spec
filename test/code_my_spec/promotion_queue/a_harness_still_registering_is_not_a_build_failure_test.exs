defmodule CodeMySpec.PromotionQueue.AHarnessStillRegisteringIsNotABuildFailureTest do
  @moduledoc """
  A source harness still registering must not eject its queued candidate.
  Rejoining wakes the queue, and a slow retry timer recovers missed join events.
  Destination availability is unrelated to admission.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.ExecutionContexts.ExecutionContext
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
      register_working_copy_execution_context(
        %{scope | active_working_copy_id: main.id},
        ExecutionContext.new(:harness, "/main", ref: %{"harness_id" => main.id})
      )

    {:ok, candidate} =
      WorkingCopies.issue(scope, nil, label: "a team", device: device_fixture(scope))

    {:ok, candidate} = WorkingCopies.report_root(candidate, "/source")

    :ok =
      register_working_copy_execution_context(
        %{scope | active_working_copy_id: candidate.id},
        ExecutionContext.new(:harness, "/source", ref: %{"harness_id" => candidate.id})
      )

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

  test "an unreachable source leaves the candidate queued with a recovery timer",
       ctx do
    :ok = PromotionQueue.ensure_worker(ctx.scope)
    # `init/1` sends itself `:next` before this call reaches it.
    state = :sys.get_state(worker_pid(ctx.scope.active_project_id))

    assert state.phase == :idle
    assert is_reference(state.timer), "a missed join must not strand this candidate forever"

    assert [waiting] = Repository.queued(ctx.scope.active_project_id, 10)
    assert waiting.id == ctx.entry.id

    assert waiting.status == :queued,
           "the candidate was taken or ejected over its source being unreachable"
  end
end
