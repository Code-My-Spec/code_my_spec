defmodule CodeMySpecTest.FakeWorkspaceRunner do
  @moduledoc """
  A `CodeMySpec.Workspaces.Runner` whose answers the test decides.

  Booting a real devbox takes minutes and needs a Docker daemon, so the
  outcomes the story cares about — it came up, it died, it never answered —
  are driven from here instead.

  ## Owned by the test that installs it, not a global singleton

  Issue 7f3a2936 (a concrete instance of 9839ae69): this used to be a single
  `Agent` registered under a fixed name, shared by every async test using this
  fake across any number of files at once. Two different failures came out of
  sharing one slot: `calls/0` and `booted_env/0`-style reads picked up another
  concurrently-running test's most recent call instead of this test's own, and
  whichever test's setup happened to stop the Agent at `on_exit` could stop it
  out from under a different, still-running test mid-scenario.

  Installing now starts an unnamed `Agent` and registers it in a `Registry`
  keyed by the test process — the same ownership-dies-with-the-process pattern
  `CodeMySpecTest.AgentTransportRouter` already uses for the same reason.
  Every read or write resolves `owner/0` first: the calling process itself, or
  whichever of its `$callers` is registered — covering a `Task` spawned off
  the test (`Workspaces.boot/1`'s own watcher), a Phoenix LiveView process
  under test (`Phoenix.LiveViewTest` puts the test pid in the connect params'
  `"caller"`, and `phoenix_live_view`'s own channel sets `$callers` to it on
  connect), and this module's own `start_link/1` called through
  `start_supervised!` (ExUnit's test supervisor has had `$callers` pointing at
  the test process in its own process dictionary since Elixir 1.17, so reading
  it from inside the synchronous `Supervisor.start_child` call that runs our
  `start_link/1` resolves it correctly). Registering under the *last* entry
  in that chain, not under `self()` directly, is what makes the
  `start_supervised!` case register under the test rather than under whatever
  ExUnit process happened to call `start_link/1` on the test's behalf.
  """

  use Agent

  @behaviour CodeMySpec.Workspaces.Runner

  @registry __MODULE__.Registry

  @doc """
  Start the registry if it is not running.

  `mix spex` loads no test helper, so the first install starts it; it is
  unlinked so it outlives whichever test happened to start it.
  """
  @spec ensure_registry() :: :ok
  def ensure_registry do
    case Registry.start_link(keys: :unique, name: @registry) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  @doc """
  Starts the fake with the outcomes this test wants, owned by the caller.

  `{:error, {:already_started, _}}` is not a crash to propagate — it is this
  same process installing a second time (two scenarios in one `spex` block
  share a process, and read as sibling blocks, not a second install of the
  same fixture). The caller already knows to read that as "reconfigure
  instead" (`CodeMySpecSpex.Fixtures.install_workspace_runner/2`).
  """
  def start_link(opts) do
    ensure_registry()
    {:ok, agent} = Agent.start_link(fn -> Map.put(outcomes(opts), :calls, []) end)

    # The *last* entry in `self()`'s own `$callers` chain, not `self()` on its
    # own: called through `start_supervised!`, `start_link/1` runs inside
    # ExUnit's test supervisor process, not the test process, and that
    # supervisor's `$callers` already names the test as its last (and only)
    # entry -- registering under its own pid instead would tie ownership to
    # the wrong process.
    owner_key = List.last([self() | Process.get(:"$callers", [])])

    case Registry.register(@registry, owner_key, agent) do
      {:ok, _} ->
        {:ok, agent}

      {:error, {:already_registered, _owner_key}} ->
        Agent.stop(agent)
        {:error, {:already_started, agent}}
    end
  end

  @doc """
  Point an already-running fake at a new set of outcomes.

  For a second `install_workspace_runner/1` in one test process. Scenarios
  inside a single `spex` block share that process, so a fixture that installed
  a runner in scenario one meets `{:already_started, #PID<...>}` in scenario
  two — an error naming a child spec and a pid, which reads as a supervision
  bug in the code under test rather than as a second call to a fixture.

  `calls` survives, deliberately. Reconfiguring says what the workspace does
  next; it does not say the context never called `start/3`, and an assertion
  about earlier calls is a reasonable thing for a later scenario to make.
  """
  def configure(opts) do
    Agent.update(owner(), &Map.merge(&1, outcomes(opts)))
  end

  defp outcomes(opts) do
    %{
      start_result: Keyword.get(opts, :start_result, :ok),
      healthy?: Keyword.get(opts, :healthy?, true),
      serving: Keyword.get(opts, :serving, :serving),
      alive?: Keyword.get(opts, :alive?, true),
      logs: Keyword.get(opts, :logs, "")
    }
  end

  @doc "Replaces what the container has announced so far."
  def put_logs(logs), do: Agent.update(owner(), &%{&1 | logs: logs})

  @doc "Sets what the app is doing: :serving, :erroring or :down."
  def put_serving(serving) when serving in [:serving, :erroring, :down, :ok] do
    Agent.update(owner(), &%{&1 | serving: normalize(serving)})
  end

  defp normalize(:ok), do: :serving
  defp normalize(other), do: other

  @doc """
  Decides, from the test, whether the instance is answering yet.

  Lets a test observe the booting state and then end it deliberately, instead
  of racing the watcher's wall-clock deadline — a race the test loses on a
  loaded machine, which is exactly where it must not be flaky.
  """
  def put_healthy(healthy?), do: Agent.update(owner(), &%{&1 | healthy?: healthy?})

  @doc "Kills the instance from the test — the container has gone away."
  def put_alive(alive?), do: Agent.update(owner(), &%{&1 | alive?: alive?})

  @doc "Every `start/3` the context made, oldest first."
  def calls, do: owner() |> Agent.get(& &1.calls) |> Enum.reverse()

  # The env is recorded rather than dropped, because "the instance was told
  # which working copy it is" is the difference between a container that
  # onboards itself and one that comes up belonging to nobody — and that is a
  # claim a test should be able to make.
  @impl true
  def start(container_name, app_name, port, env \\ []) do
    Agent.get_and_update(owner(), fn state ->
      {state.start_result,
       %{state | calls: [{container_name, app_name, port, env} | state.calls]}}
    end)
  end

  @impl true
  def healthy?(_port), do: Agent.get(owner(), & &1.healthy?)

  @impl true
  def serving(_port), do: Agent.get(owner(), & &1.serving)

  @impl true
  def url(_container_name, port), do: "http://localhost:#{port}"

  # Config wins over the agent's own state when set, so a spex can kill the
  # instance mid-run without calling across a boundary into this module.
  @impl true
  def alive?(_container_name) do
    case Application.get_env(:code_my_spec, :fake_workspace_alive) do
      nil -> Agent.get(owner(), & &1.alive?)
      alive? -> alive?
    end
  end

  @impl true
  def logs(_container_name), do: Agent.get(owner(), & &1.logs)

  @impl true
  def stop(_container_name), do: :ok

  defp owner, do: owner([self() | Process.get(:"$callers", [])])

  defp owner([]) do
    raise "No #{inspect(__MODULE__)} installed for this process, or anything in its " <>
            "$callers chain -- call CodeMySpecSpex.Fixtures.install_workspace_runner/2 " <>
            "(or, in a plain _test.exs file, start_supervised!({#{inspect(__MODULE__)}, opts})) " <>
            "in this test's own setup first."
  end

  defp owner([pid | rest]) do
    case Registry.lookup(@registry, pid) do
      [{_registrant, agent}] -> agent
      [] -> owner(rest)
    end
  end
end
