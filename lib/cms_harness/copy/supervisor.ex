defmodule CmsHarness.Copy.Supervisor do
  @moduledoc """
  Everything this harness runs for one working copy, under one supervisor: the
  tree mirrors copy → agents (John, phase 2b).

      Copy.Supervisor        one per root, :one_for_one
       ├ apps   DynamicSupervisor — the copy's own app (`AppInstance`), on demand
       ├ agents DynamicSupervisor — an `Engine.Keeper` per agent
       └ Project.Supervisor  the channel chain, once the copy is served

  Siblings, not one chain. A channel blip restarts the project chain
  (`Project.Supervisor` is `:rest_for_one` inside) and nothing else: the agents
  and the app keep running, and the rejoin reports them. Offboarding is
  terminating this supervisor — every agent, the app and the channel go with
  it, in one place, with no list of things to remember to stop.

  `Project.Supervisor` is added when the copy is served (`serve/2`), not at
  start: an agent runs in a copy whether or not this harness serves its project
  — a test's scratch directory, a copy being prepared.

  Generous restart intensity, because the children restart themselves: this
  only gives up when the copy itself is beyond saving.
  """

  use Supervisor, restart: :temporary

  @copies CmsHarness.CopiesSupervisor

  def start_link(root), do: Supervisor.start_link(__MODULE__, root, name: via(root))

  @impl true
  def init(root) do
    children = [
      Supervisor.child_spec({DynamicSupervisor, name: apps(root), strategy: :one_for_one},
        id: :apps
      ),
      Supervisor.child_spec({DynamicSupervisor, name: agents(root), strategy: :one_for_one},
        id: :agents
      )
    ]

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 10, max_seconds: 60)
  end

  @doc "The copy at `root`'s supervisor, started if it is not running."
  @spec ensure(String.t()) :: {:ok, pid()} | {:error, term()}
  def ensure(root) do
    root = Path.expand(root)

    case DynamicSupervisor.start_child(@copies, {__MODULE__, root}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _} = error -> error
    end
  end

  @doc """
  Name the supervisor that serves a copy — its channel chain. Called once by
  `CmsHarness.Supervisor` at boot, so this supervisor, which everything below
  the channel uses to find a copy's agents and app, does not depend on the
  channel layer it starts.
  """
  @spec serve_with(module()) :: :ok
  def serve_with(module) when is_atom(module),
    do: :persistent_term.put({__MODULE__, :served_by}, module)

  defp served_by, do: :persistent_term.get({__MODULE__, :served_by})

  @doc """
  Serve `project` in its copy: its channel chain, under the copy.
  `{:started, pid}`, or `{:already_started, pid}` when it was served already.
  """
  @spec serve(String.t(), map()) ::
          {:started | :already_started, pid()} | {:error, term()}
  def serve(root, project) do
    with {:ok, copy} <- ensure(root) do
      case Supervisor.start_child(copy, {served_by(), project: project}) do
        {:ok, pid} -> {:started, pid}
        {:error, {:already_started, pid}} -> {:already_started, pid}
        {:error, _} = error -> error
      end
    end
  end

  @doc """
  Stop serving the copy at `root` — its channel chain — and leave its agents
  and its app running. A rejoin is this and `serve/2`.
  """
  @spec unserve(String.t()) :: :ok | {:error, :not_serving}
  def unserve(root) do
    with {:ok, copy} <- whereis(root),
         :ok <- Supervisor.terminate_child(copy, served_by()) do
      Supervisor.delete_child(copy, served_by())
    else
      _ -> {:error, :not_serving}
    end
  end

  @doc "Stop everything this harness runs for the copy at `root`."
  @spec stop(String.t()) :: :ok | {:error, :not_found}
  def stop(root) do
    case whereis(root) do
      {:ok, pid} -> DynamicSupervisor.terminate_child(@copies, pid)
      {:error, _} -> {:error, :not_found}
    end
  end

  # Registry drops a dead process's entry asynchronously, so a lookup just
  # after `stop/1` can still return the terminated pid.
  @spec whereis(String.t()) :: {:ok, pid()} | {:error, :not_running}
  def whereis(root) do
    case Registry.lookup(CmsHarness.Registry, {:copy, Path.expand(root)}) do
      [{pid, _}] -> if Process.alive?(pid), do: {:ok, pid}, else: {:error, :not_running}
      [] -> {:error, :not_running}
    end
  end

  @doc "Where the copy at `root`'s app runs."
  def apps(root), do: {:via, Registry, {CmsHarness.Registry, {:apps, Path.expand(root)}}}

  @doc "Where the copy at `root`'s agents run."
  def agents(root), do: {:via, Registry, {CmsHarness.Registry, {:agents, Path.expand(root)}}}

  defp via(root), do: {:via, Registry, {CmsHarness.Registry, {:copy, root}}}
end
