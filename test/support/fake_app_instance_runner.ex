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
      clone_result: Keyword.get(opts, :clone_result, Map.get(base, :clone_result, :ok)),
      current_commit: Keyword.get(opts, :current_commit, Map.get(base, :current_commit, "abc1234")),
      launch_result: Keyword.get(opts, :launch_result, Map.get(base, :launch_result, {:ok, next_fake_pid()})),
      alive?: Keyword.get(opts, :alive?, Map.get(base, :alive?, true)),
      probe: Keyword.get(opts, :probe, Map.get(base, :probe, :serving))
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

  @impl true
  def launch(root, port, https_port, database, log_path) do
    record(:launch, [root, port, https_port, database, log_path])
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
end
