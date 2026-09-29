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

  Taking the difference since a snapshot is not enough either: a child
  another async test starts inside the window looks new. The async
  `FakeWorkspaceRunnerReinstallTest` killed `CodeModeTest`'s eval tasks that
  way — `"the script died: :killed"`. So a new child is killed only if it is
  a watcher, told by the `$initial_call` `Task.Supervisor` records: a fun
  defined in `CodeMySpec.Workspaces`, where `watch/1` starts it.
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
    |> Enum.filter(&watcher?/1)
    |> Enum.each(&Process.exit(&1, :kill))
  end

  @doc """
  The watchers running right now, to be handed back to `kill_since/1` after
  the test has started more.
  """
  @spec running() :: [pid()]
  def running, do: children()

  # `Task.Supervisor` records the spawning fun as the task's `$initial_call`;
  # for a watcher that is `{CodeMySpec.Workspaces, :"-watch/1-fun-0-", 0}`.
  # `nil` is a task that already exited.
  defp watcher?(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        match?({CodeMySpec.Workspaces, _, _}, dictionary[:"$initial_call"])

      nil ->
        false
    end
  end

  defp children do
    Task.Supervisor.children(@supervisor)
  rescue
    # The supervisor is part of the web application; a test that runs without
    # it started has no watchers to clean up either.
    _ -> []
  end
end
