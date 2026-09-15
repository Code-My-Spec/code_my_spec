defmodule CodeMySpec.Analysis.ProjectServer do
  @moduledoc """
  Per-working-copy analysis queue: single-flight dedup + serialized execution.

  One GenServer per working copy (Registry + DynamicSupervisor). All analyzer
  subprocesses for one checkout funnel through here at a time — exunit and spex
  share that checkout's `_build`, and target projects on older Elixir have no OS
  build lock, so concurrent mix runs there can corrupt the build.

  ## Why the working copy and not the project

  It was keyed on the project, which is the same serialization for a machine
  running one checkout and far too much for a machine running several: three
  worktrees of one project queued behind each other for no shared resource.
  Sweeps here run 200-590s, so the wait was minutes, and it surfaced as a stop
  refused `:no_reply` six seconds before another checkout's suite finished —
  with a message blaming the server or the network.

  The constraint the serialization exists for is per checkout, not per project:
  `AnalyzerEnv.extra_env/1` gives each working copy its own `MIX_BUILD_PATH` and
  its own test database, so two checkouts share nothing to corrupt. Within one,
  exunit and spex still share a build tree and still take turns.

  `remote_executor/1` was already keyed this way, for the same reason stated in
  its own comment. This makes the queue agree with it.

  The key is the harness id — the working copy — falling back to the project
  when there is no harness, which is the single-checkout case where the two are
  the same thing anyway. The PubSub topic stays `analysis:<project_id>`: a
  LiveView watches a project, and which checkout produced a result is not
  something it subscribes by.

  Dedup: a request matching a running or queued job (same source + args +
  input fingerprint) joins it instead of double-running. Await callers are
  held as `from` tuples and replied when the job lands. Queued (unwatched)
  full runs for a source are superseded when a newer fingerprint arrives —
  only the latest inputs matter.

  Execution happens in a `Task.Supervisor.async_nolink` task that owns the
  whole runner → reconcile path (`Analysis.Execution`), so results persist
  even if this server — or the HTTP request that triggered it — dies mid-run.
  """

  use GenServer, restart: :transient

  require Logger

  alias CodeMySpec.Analysis.{Execution, Reconciler, RunsRepository}
  alias CodeMySpec.Users.Scope

  # Generous ceiling for one analyzer subprocess; a hung mix run must not
  # wedge the project queue forever.
  @job_timeout :timer.minutes(30)

  # -- Client --

  def start_link({key, project_id}) do
    GenServer.start_link(__MODULE__, {key, project_id}, name: via(key))
  end

  def via(key) do
    {:via, Registry, {CodeMySpec.Analysis.Registry, key}}
  end

  @doc """
  Enqueue a job unless an equivalent one is running/queued (fire-and-forget).

  Returns `{:ok, :started | :joined, run_id}`.
  """
  def ensure_run(server, %Scope{} = scope, job) do
    GenServer.call(server, {:ensure, scope, job})
  end

  @doc """
  Enqueue (or join) a job and block until it finishes.

  Returns `{:ok, %Run{}}` for a finished run or `{:error, reason}`.
  """
  def await_run(server, %Scope{} = scope, job) do
    GenServer.call(server, {:await, scope, job}, :infinity)
  end

  @doc "Sources currently running or queued."
  def in_flight(server) do
    GenServer.call(server, :in_flight)
  end

  # -- Server --

  @impl true
  def init({key, project_id}) do
    {:ok,
     %{
       key: key,
       project_id: project_id,
       running: nil,
       queue: [],
       waiters: %{},
       timeout_ref: nil
     }}
  end

  @impl true
  def handle_call({:ensure, scope, job}, _from, state) do
    case find_match(state, job) do
      {:ok, run_id} ->
        {:reply, {:ok, :joined, run_id}, state}

      :none ->
        case enqueue(state, scope, job) do
          {:ok, run_id, state} -> {:reply, {:ok, :started, run_id}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:await, scope, job}, from, state) do
    case find_match(state, job) do
      {:ok, run_id} ->
        {:noreply, add_waiter(state, run_id, from)}

      :none ->
        case enqueue(state, scope, job) do
          {:ok, run_id, state} -> {:noreply, add_waiter(state, run_id, from)}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call(:in_flight, _from, state) do
    running = if state.running, do: [state.running.job.source], else: []
    queued = Enum.map(state.queue, & &1.job.source)
    {:reply, Enum.uniq(running ++ queued), state}
  end

  @impl true
  def handle_info({ref, result}, %{running: %{task: %{ref: ref}}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_current(state, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{running: %{task: %{ref: ref}}} = state) do
    # The task died before reconciling — close its ledger row here so it
    # can't sit :running forever.
    Reconciler.fail(state.running.run, {:task_died, reason})
    {:noreply, finish_current(state, {:error, {:task_died, reason}})}
  end

  def handle_info({:job_timeout, run_id}, %{running: %{run: %{id: run_id}}} = state) do
    Logger.warning("[Analysis] job timeout — killing #{state.running.job.source} run #{run_id}")
    Task.Supervisor.terminate_child(CodeMySpec.Analysis.TaskSupervisor, state.running.task.pid)
    Reconciler.fail(state.running.run, :timeout)
    {:noreply, finish_current(state, {:error, :timeout})}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Internals --

  defp find_match(state, job) do
    candidates =
      case state.running do
        nil -> state.queue
        entry -> [entry | state.queue]
      end

    case Enum.find(candidates, &same_job?(&1.job, job)) do
      nil -> :none
      entry -> {:ok, entry.run.id}
    end
  end

  defp same_job?(a, b) do
    a.source == b.source and a.args == b.args and a.fingerprint == b.fingerprint
  end

  defp enqueue(state, scope, job) do
    case RunsRepository.start_run(scope, %{
           source: job.source,
           kind: job.kind,
           args: %{"args" => job.args},
           input_fingerprint: job.fingerprint,
           requested_by: job.requested_by
         }) do
      {:ok, run} ->
        broadcast(state.project_id, job.source, :running, run.id)

        entry = %{job: job, run: run, scope: scope, task: nil}

        state =
          state
          |> supersede_queued(job)
          |> Map.update!(:queue, &order(&1 ++ [entry]))
          |> maybe_start_next()

        {:ok, run.id, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Cheapest source first. Runs here are serialized, and these four differ by
  # three orders of magnitude — credo answers in milliseconds, spex in minutes.
  # Strict FIFO meant a stop hook waiting only on credo sat behind a spex run
  # that had nothing to do with it, and the agent was told "analysis pending"
  # for three and a half minutes with the answer already computable. Five
  # consecutive stops went that way before the queue was the suspect, because
  # from the outside a slow queue and a broken analyzer look identical.
  #
  # `Enum.sort_by` is stable, so equal ranks keep the order they arrived in —
  # this reorders across sources without disturbing FIFO within one.
  #
  # Starvation is bounded rather than prevented: there are four sources and
  # same-fingerprint jobs dedup, so a finite burst drains. A source that
  # re-enqueued faster than it ran could hold off spex, and if that ever shows
  # up the fix is aging, not a bigger table.
  @source_cost %{"credo" => 0, "compiler" => 1, "exunit" => 2, "spex" => 3}

  @doc false
  # Public only so the ordering policy can be asserted without a database and
  # four live analyzer subprocesses behind it.
  def order(queue) do
    Enum.sort_by(queue, &Map.get(@source_cost, &1.job.source, 9))
  end

  # A newer full run for a source obsoletes queued (not running, unwatched)
  # full runs of the same source at an older fingerprint.
  defp supersede_queued(state, %{kind: :full} = job) do
    {stale, keep} =
      Enum.split_with(state.queue, fn entry ->
        entry.job.kind == :full and entry.job.source == job.source and
          entry.job.fingerprint != job.fingerprint and
          not Map.has_key?(state.waiters, entry.run.id)
      end)

    Enum.each(stale, fn entry ->
      Reconciler.fail(entry.run, :superseded)
      broadcast(state.project_id, entry.job.source, :failed, entry.run.id)
    end)

    %{state | queue: keep}
  end

  defp supersede_queued(state, _job), do: state

  defp maybe_start_next(%{running: nil, queue: [entry | rest]} = state) do
    task =
      Task.Supervisor.async_nolink(CodeMySpec.Analysis.TaskSupervisor, fn ->
        Execution.execute(entry.scope, entry.run, entry.job.opts)
      end)

    timeout_ref = Process.send_after(self(), {:job_timeout, entry.run.id}, @job_timeout)

    %{state | running: %{entry | task: task}, queue: rest, timeout_ref: timeout_ref}
  end

  defp maybe_start_next(state), do: state

  defp finish_current(state, result) do
    %{run: run, job: job} = state.running

    if state.timeout_ref, do: Process.cancel_timer(state.timeout_ref)

    status =
      case result do
        {:ok, %{status: status}} -> status
        _ -> :failed
      end

    broadcast(state.project_id, job.source, status, run.id)
    reply_waiters(state, run.id, result)

    %{state | running: nil, timeout_ref: nil, waiters: Map.delete(state.waiters, run.id)}
    |> maybe_start_next()
  end

  defp add_waiter(state, run_id, from) do
    %{state | waiters: Map.update(state.waiters, run_id, [from], &[from | &1])}
  end

  defp reply_waiters(state, run_id, result) do
    state.waiters
    |> Map.get(run_id, [])
    |> Enum.each(&GenServer.reply(&1, result))
  end

  defp broadcast(project_id, source, status, run_id) do
    Phoenix.PubSub.broadcast(
      CodeMySpec.PubSub,
      "analysis:#{project_id}",
      {:analysis, %{source: source, status: status, run_id: run_id}}
    )
  end
end
