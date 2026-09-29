defmodule CmsHarnessTest.FakeAppInstanceRunner do
  @moduledoc """
  A `CmsHarness.AppInstance.Runner` whose answers the test decides.

  Same reasoning as `CodeMySpecTest.FakeWorkspaceRunner`: this project's own
  rule is that tests do not shell out to real tools — no `just`, no `psql`,
  no real detached OS process. The outcomes story 1108's criteria care about
  — a database that already exists, one that doesn't, an app that never
  answers, a copy with no `serve` recipe — are driven from here instead, at
  full speed and without a Postgres server or `just` on the test machine's
  PATH being part of what's under test.

  `CmsHarness.AppInstance` itself — the orchestration this fake makes fast
  and deterministic to exercise — was verified once for real, by hand,
  against this project's own working copy (story 1108's handoff): a real
  `just serve` came up on an allocated port and served that commit's actual
  homepage, then a real stop took it down cleanly.
  """

  use Agent

  @behaviour CmsHarness.AppInstance.Runner

  def start_link(opts \\ []) do
    Agent.start_link(fn -> Map.put(defaults(opts), :calls, []) end, name: __MODULE__)
  end

  @doc "Point an already-running fake at a new set of outcomes — see `FakeWorkspaceRunner.configure/1`."
  def configure(opts) do
    Agent.update(__MODULE__, &Map.merge(&1, defaults(opts, &1)))
  end

  defp defaults(opts, base \\ %{}) do
    %{
      recipe?: Map.get(base, :recipe?, %{"serve" => true, "seed" => false}) |> Map.merge(Keyword.get(opts, :recipe, %{})),
      app_name: Keyword.get(opts, :app_name, Map.get(base, :app_name, "fakeapp")),
      database_exists?: Keyword.get(opts, :database_exists?, Map.get(base, :database_exists?, false)),
      main_database_name: Keyword.get(opts, :main_database_name, Map.get(base, :main_database_name, "fakeapp_dev")),
      main_ports: Keyword.get(opts, :main_ports, Map.get(base, :main_ports, {4000, 4001})),
      clone_result: Keyword.get(opts, :clone_result, Map.get(base, :clone_result, :ok)),
      current_commit: Keyword.get(opts, :current_commit, Map.get(base, :current_commit, "abc1234")),
      after_promote_result: Keyword.get(opts, :after_promote_result, Map.get(base, :after_promote_result, :ok)),
      listener_pid: Keyword.get(opts, :listener_pid, Map.get(base, :listener_pid, nil)),
      process_root: Keyword.get(opts, :process_root, Map.get(base, :process_root, nil)),
      launch_result: Keyword.get(opts, :launch_result, Map.get(base, :launch_result, {:ok, next_fake_pid()})),
      alive?: Keyword.get(opts, :alive?, Map.get(base, :alive?, true)),
      probe: Keyword.get(opts, :probe, Map.get(base, :probe, :serving)),
      start_tunnel_result: Keyword.get(opts, :start_tunnel_result, Map.get(base, :start_tunnel_result, :ok))
    }
  end

  defp next_fake_pid, do: System.unique_integer([:positive, :monotonic])

  @doc "Sets whether `root`'s justfile declares `name` — defaults: serve true, seed false."
  def put_recipe(name, present?) do
    Agent.update(__MODULE__, fn state -> %{state | recipe?: Map.put(state.recipe?, name, present?)} end)
  end

  @doc "Sets what `database_exists?/1` answers — flips true after a successful `clone_database/3` on its own."
  def put_database_exists(exists?), do: Agent.update(__MODULE__, &%{&1 | database_exists?: exists?})

  @doc "Sets what `clone_database/3` answers — `:ok` or `{:error, reason}`."
  def put_clone_result(result), do: Agent.update(__MODULE__, &%{&1 | clone_result: result})

  @doc "Sets what `launch/5` answers — `{:ok, os_pid}` or `{:error, reason}`."
  def put_launch_result(result), do: Agent.update(__MODULE__, &%{&1 | launch_result: result})

  @doc "Sets what `alive?/1` answers, from the test — a process this fake never really spawned."
  def put_alive(alive?), do: Agent.update(__MODULE__, &%{&1 | alive?: alive?})

  @doc "Sets what `probe/1` answers: `:serving`, `:erroring` or `:down`."
  def put_probe(status) when status in [:serving, :erroring, :down],
    do: Agent.update(__MODULE__, &%{&1 | probe: status})

  @doc "Every call this fake recorded, oldest first — `{function, args}` pairs."
  def calls, do: __MODULE__ |> Agent.get(& &1.calls) |> Enum.reverse()

  defp record(name, args), do: Agent.update(__MODULE__, &%{&1 | calls: [{name, args} | &1.calls]})

  @impl true
  def recipe?(root, name) do
    record(:recipe?, [root, name])
    Agent.get(__MODULE__, &Map.get(&1.recipe?, name, false))
  end

  @impl true
  def free_port, do: Agent.get_and_update(__MODULE__, &{next_fake_port(&1), &1})

  defp next_fake_port(_state), do: 40_000 + :erlang.unique_integer([:positive, :monotonic])

  @impl true
  def app_name(root) do
    record(:app_name, [root])
    Agent.get(__MODULE__, & &1.app_name)
  end

  @impl true
  def database_exists?(database) do
    record(:database_exists?, [database])
    Agent.get(__MODULE__, & &1.database_exists?)
  end

  @impl true
  def main_database_name(root) do
    record(:main_database_name, [root])
    Agent.get(__MODULE__, & &1.main_database_name)
  end

  @doc "Sets what `main_ports/1` answers — `{http, https}` or `nil`."
  def put_main_ports(ports), do: Agent.update(__MODULE__, &%{&1 | main_ports: ports})

  @impl true
  def main_ports(root) do
    record(:main_ports, [root])
    Agent.get(__MODULE__, & &1.main_ports)
  end

  @impl true
  def clone_database(root, main_database, database) do
    record(:clone_database, [root, main_database, database])
    result = Agent.get(__MODULE__, & &1.clone_result)
    if result == :ok, do: put_database_exists(true)
    result
  end

  @impl true
  def seed(root) do
    record(:seed, [root])
    :ok
  end

  @impl true
  def drop_database(database) do
    record(:drop_database, [database])
    put_database_exists(false)
    :ok
  end

  @impl true
  def current_commit(root) do
    record(:current_commit, [root])
    Agent.get(__MODULE__, & &1.current_commit)
  end

  @doc "Sets what `run_after_promote/1` answers — `:ok` or `{:error, reason}`."
  def put_after_promote_result(result), do: Agent.update(__MODULE__, &%{&1 | after_promote_result: result})

  @impl true
  def run_after_promote(root) do
    record(:run_after_promote, [root])
    Agent.get(__MODULE__, & &1.after_promote_result)
  end

  @impl true
  def launch(root, port, https_port, database, log_path, main?, tunnel_held_by_harness?) do
    record(:launch, [root, port, https_port, database, log_path, main?, tunnel_held_by_harness?])

    # `running?/1` in real `AppInstance` now checks `process_root(pid) ==
    # root` before trusting `alive?/1` — see criterion 1589. Defaulting to
    # "yes, still this copy" here is what every *other* criterion needs:
    # they exercise the ordinary path, not the recycled-pid one, and would
    # otherwise all have to configure this just to keep `running?/1` true
    # after a launch that plainly just happened. A criterion about the
    # mismatch itself calls `put_process_root/1` afterward to override it.
    Agent.update(__MODULE__, &%{&1 | process_root: root})

    Agent.get(__MODULE__, & &1.launch_result)
  end

  @impl true
  def alive?(os_pid) do
    record(:alive?, [os_pid])
    Agent.get(__MODULE__, & &1.alive?)
  end

  @impl true
  def probe(port) do
    record(:probe, [port])
    Agent.get(__MODULE__, & &1.probe)
  end

  @impl true
  def stop_process(os_pid) do
    record(:stop_process, [os_pid])
    put_alive(false)
    :ok
  end

  @doc "Sets what `listener_pid/1` answers — an os_pid, or `nil` for \"nothing is listening\"."
  def put_listener_pid(pid), do: Agent.update(__MODULE__, &%{&1 | listener_pid: pid})

  @impl true
  def listener_pid(port) do
    record(:listener_pid, [port])
    Agent.get(__MODULE__, & &1.listener_pid)
  end

  @doc "Sets what `process_root/1` answers for whatever `listener_pid/1` returns."
  def put_process_root(root), do: Agent.update(__MODULE__, &%{&1 | process_root: root})

  @impl true
  def process_root(os_pid) do
    record(:process_root, [os_pid])
    Agent.get(__MODULE__, & &1.process_root)
  end

  @doc "Sets what `start_tunnel/2` answers — `:ok` (a real, checkable fake pid) or `{:error, reason}`."
  def put_start_tunnel_result(result), do: Agent.update(__MODULE__, &%{&1 | start_tunnel_result: result})

  @impl true
  def start_tunnel(credentials, origin_url) do
    record(:start_tunnel, [credentials, origin_url])

    case Agent.get(__MODULE__, & &1.start_tunnel_result) do
      :ok ->
        # A real, if trivial, process — `AppInstance.ensure_tunnel/3` calls
        # `Process.alive?/1` on what this returns, and that has to answer
        # honestly for a pid nothing here actually made a tunnel out of.
        {:ok, pid} = Agent.start(fn -> :ok end)
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def stop_tunnel(pid) do
    record(:stop_tunnel, [pid])
    if Process.alive?(pid), do: Agent.stop(pid)
    :ok
  end
end
