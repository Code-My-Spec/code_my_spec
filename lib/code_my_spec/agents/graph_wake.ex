defmodule CodeMySpec.Agents.GraphWake do
  @moduledoc """
  Wakes a project's agents when its requirement graph changes, and keeps a
  graph watcher running for every project that has an agent in the loop.

  The graph emits `[:code_my_spec, :requirements, :graph_changed]` after a
  recompute that consumed something, and this handler answers it. The graph
  used to call `Work.consider_project/2` itself, and read the agents table at
  boot to decide which projects to watch — which made `Requirements` depend on
  `Agents`, the thing computed over depending on the thing that acts on it.

  A `:telemetry` handler, attached at application start, for the same reason as
  `Agents.AnalysisReport`: it runs synchronously in the emitting process, so it
  behaves as the direct call did.

  ## Off the emitting process

  The handler only *starts* the wake. Waking renders each role's menu, the menu
  counts requirements, and counting them can call `GraphWatcher.settle/1` — a
  call to the watcher that emitted this. Waking inline would be the watcher
  calling itself, and the agent that had been waiting would be waiting on a
  deadlock.
  """

  require Logger

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.Requirements.GraphWatcher

  @event [:code_my_spec, :requirements, :graph_changed]

  @doc "The event the graph emits when it has changed in a way worth waking for."
  def event, do: @event

  @doc "Attach the handler. Called once, after the application tree starts."
  def attach do
    :telemetry.attach({__MODULE__, :wake}, @event, &__MODULE__.handle_event/4, nil)
  end

  # Rescued and logged rather than left to raise: `:telemetry` detaches a
  # handler that raises, permanently, so one bad wake would silently end every
  # later one. Logged at error each time, not swallowed.
  @doc false
  def handle_event(@event, _measurements, %{scope: scope}, _config) do
    Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
      Work.consider_project(scope, :graph_changed)
    end)

    :ok
  rescue
    e ->
      Logger.error(
        "[GraphWake] waking project #{inspect(scope.active_project_id)} failed: " <>
          Exception.format(:error, e, __STACKTRACE__)
      )
  end

  @doc """
  Start a watcher for every project that has an agent in the loop.

  Watchers live in memory, so a restart takes them all — and nothing recreated
  them until somebody toggled a loop. That is the worst possible time to lose
  them: a deploy is exactly when agents are mid-run, and an agent that goes idle
  after one has nothing watching for the work that would wake it.

  Called at boot. A project with nobody working it stays unwatched, which is the
  same rule `GraphWatcher.ensure_watching/1` follows on demand.

  Best-effort by design: a project whose scope cannot be built is skipped rather
  than taking the boot down with it, and the next stop decision on that project
  starts its watcher anyway.
  """
  @spec watch_active_projects() :: :ok
  def watch_active_projects do
    AgentsRepository.continuous_project_scopes()
    |> Enum.each(fn scope ->
      case GraphWatcher.ensure_watching(scope) do
        {:ok, _pid} ->
          :ok

        other ->
          Logger.warning(
            "[GraphWake] could not watch #{scope.active_project_id}: #{inspect(other)}"
          )
      end
    end)
  end
end
