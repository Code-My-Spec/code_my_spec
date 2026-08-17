defmodule CodeMySpecTest.WorkspaceWatchers do
  @moduledoc """
  Teardown for the boot watchers `Workspaces.boot/1` leaves running.

  A watcher that outlives its test falls back to the default runner — which
  is the real Docker one — and polls it for the default fifteen minutes,
  dragging the rest of the suite with it. So it has to be killed, and killed
  *before* the fake-runner config is cleared, or it wakes up pointed at
  Docker for the moment in between.

  What this exists to scope is which watchers. Both call sites used to do

      CodeMySpec.TaskSupervisor
      |> Task.Supervisor.children()
      |> Enum.each(&Process.exit(&1, :kill))

  which is every child of an **application-wide** supervisor, not every child
  this test started. `Provisioning`, `Workspaces`, `refresh_embeddings` and
  `HarnessProjectChannel` all start children there, so that line kills other
  tests' work as readily as its own.

  It is harmless today only because both callers are `async: false` and
  ExUnit finishes the async phase before the sync one begins — there is
  nothing else running to hit. That is not a property either file states or
  can enforce, and this pass has been moving files *to* async. A landmine
  that arms itself when someone adds `async: true` is worth defusing while
  the reason is still in front of us: `Task.Supervisor.start_child/2` leaves
  the task unlinked, so what a stray kill produces is not a crash but a
  missing result — an assertion failing in a file that has nothing to do with
  the one that fired.

  Taking the difference is not airtight either: a child another test starts
  between the snapshot and the teardown looks new. It is bounded to that
  window rather than to the whole supervisor, and the pid is never handed
  back — `Workspaces.watch/1` is private and returns nothing to a caller —
  so the difference is what is available without changing production code to
  suit a test.
  """

  @supervisor CodeMySpec.TaskSupervisor

  @doc """
  Snapshots the watchers already running, and registers an `on_exit` that
  kills only the ones that appeared since — then clears the config, in that
  order.
  """
  @spec reset_on_exit() :: :ok
  def reset_on_exit do
    started_before = children()

    ExUnit.Callbacks.on_exit(fn ->
      kill_since(started_before)

      Application.delete_env(:code_my_spec, CodeMySpec.Workspaces)
    end)
  end

  @doc """
  Kills the watchers started since `started_before`, and only those.
  """
  @spec kill_since([pid()]) :: :ok
  def kill_since(started_before) do
    children()
    |> Kernel.--(started_before)
    |> Enum.each(&Process.exit(&1, :kill))
  end

  @doc """
  The watchers running right now, to be handed back to `kill_since/1` after
  the test has started more.
  """
  @spec running() :: [pid()]
  def running, do: children()

  defp children do
    Task.Supervisor.children(@supervisor)
  rescue
    # The supervisor is part of the web application; a test that runs without
    # it started has no watchers to clean up either.
    _ -> []
  end
end
