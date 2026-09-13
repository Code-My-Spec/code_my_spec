defmodule CodeMySpec.Requirements.ARecomputeThatActuallyFailsTest do
  @moduledoc """
  A graph recompute that fails for a reason that is a fault.

  Issue `3ad5e45c` closed a day of looking with "every remaining path either
  succeeds or means the project is gone" — `Preloader.load/1` is `Repo.all`, the
  file side channel is gone, and `wake_project_roles/1` runs in a Task whose
  failures never reach the rescue. The seam that looked like one, deleting a
  project underneath a running watcher, turned out to be *completion*: a watcher
  with nothing left to recompute has finished, and stopping is right.

  So the machinery criterion 3248 describes was real, right, and exercised by
  nothing: a genuine fault logs at `:error` and lands on `status/1` as
  `last_error`, which the requirements graph page renders.

  The issue named two ways forward and asked for a decision rather than more
  looking. This is the second one — a deliberate fault, keyed on the project so
  it reaches one watcher and no other.

  A raise rather than an error tuple, because the thing under test is the
  `rescue`. A seam that returned a tuple would exercise a path production never
  takes and pass.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Faults
  alias CodeMySpec.Requirements.GraphInputs
  alias CodeMySpec.Requirements.GraphWatcher

  setup do
    scope = full_scope_fixture()
    project_id = scope.active_project_id

    on_exit(fn ->
      Faults.clear(project_id, :graph_recompute_fails)
      stop_watching(project_id)
    end)

    %{scope: scope, project_id: project_id}
  end

  # A watcher outlives the test that started it, and the sandbox transaction
  # rolls back underneath it — so a straggler recomputes against a project that
  # no longer exists and its connection error lands in whichever test is running
  # next. `3ad5e45c` records that crossfire reaching a spex on an unrelated
  # story, so this run cleans up after itself rather than leaving it to chance.
  defp stop_watching(project_id) do
    CodeMySpec.Requirements.Registry
    |> Registry.lookup(project_id)
    |> terminate_watcher()
  end

  defp terminate_watcher([{pid, _}]),
    do: DynamicSupervisor.terminate_child(CodeMySpec.Requirements.WatcherSupervisor, pid)

  defp terminate_watcher([]), do: :ok

  # A watcher recomputes when its inputs move, not on demand, so the change has
  # to be announced before there is anything to settle. `settle/1` then blocks
  # until the debounced pass has run, which is what makes this a measurement
  # rather than a race.
  defp settled(scope) do
    {:ok, _pid} = GraphWatcher.ensure_watching(scope)
    :ok = GraphInputs.changed(scope.active_project_id)
    GraphWatcher.settle(scope.active_project_id)
    settled_tasks()
    GraphWatcher.status(scope.active_project_id)
  end

  # A healthy recompute spawns `wake_project_roles/1` off its own process — it
  # has to, because waking can call back into the watcher and a watcher waiting
  # on itself is a deadlock. That task outlives the test, and the sandbox
  # transaction rolls back underneath it, so the run carries a connection crash
  # for work that was doing exactly what it should.
  defp settled_tasks(remaining \\ 100)
  defp settled_tasks(0), do: :ok

  defp settled_tasks(remaining),
    do: still_waking(Task.Supervisor.children(CodeMySpec.TaskSupervisor), remaining)

  defp still_waking([], _remaining), do: :ok

  defp still_waking(_children, remaining) do
    Process.sleep(20)
    settled_tasks(remaining - 1)
  end

  test "is recorded as last_error rather than taking the watcher down", %{
    scope: scope,
    project_id: project_id
  } do
    healthy = settled(scope)

    assert healthy.last_error == nil,
           "the premise failed: this watcher was already carrying an error"

    :ok = Faults.inject(project_id, :graph_recompute_fails)

    faulted = settled(scope)

    assert %{message: message} = faulted.last_error, """
    A recompute raised and the watcher recorded nothing, so the requirements
    graph page has nothing to show and the fault is invisible to everyone
    except whoever is tailing the log. That is the whole of criterion 3248.
    """

    assert message =~ "graph recompute failed"
  end

  test "and the watcher recovers once it is cleared", %{scope: scope, project_id: project_id} do
    :ok = Faults.inject(project_id, :graph_recompute_fails)
    assert settled(scope).last_error != nil

    :ok = Faults.clear(project_id, :graph_recompute_fails)

    assert settled(scope).last_error == nil, """
    The error is sticky, so a watcher that recovered still reads as broken and
    the page keeps showing a fault that is over.
    """
  end

  test "and reaches only the project it was injected against", %{
    scope: scope,
    project_id: project_id
  } do
    other = full_scope_fixture()

    :ok = Faults.inject(project_id, :graph_recompute_fails)

    assert settled(other).last_error == nil, """
    One project's injected fault broke another project's watcher. A fault that
    reaches the install is the node-global switch this seam exists to replace
    (0fb7bf03).
    """
  end
end
