defmodule CodeMySpec.Analysis do
  @moduledoc """
  The analysis run service: what ran, when, over which inputs, and the single
  execution path for every analyzer request.

  Analyzer sources (`compiler`, `credo`, `exunit`, `spex`) execute as
  supervised background jobs, serialized per working copy, with results
  reconciled into Problems and recorded in the `analysis_runs` ledger. The
  latest completed `:full` run answers for its source, however old; whether it
  ran at a given commit is `Run.at_commit?/2`, which the promote gate reads.

  Entry points:

  - `ensure_stale_runs/3` — explicit analysis (`start_analysis`, ready-for-QA
    certification, promotion): enqueue, return immediately.
  - `start_run/4` — admit one run and return its id.
  - `await_run/4` — model-invoked (`mix test` rewrite) and MCP callers:
    join-or-start, block until finished, get the run back with output.
  - `runs_in_flight?/1`, `in_flight_state/1`, `status/1` — decision and UI reads.

  A run executes locally, through the per-copy `ProjectServer`, or on the
  harness holding the working copy's channel (`remote_executor/1`), whose
  result returns through `record_remote_result/2`.
  See knowledge/analysis, "Where a run executes".
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.BddSpecs,
      CodeMySpec.Compile,
      CodeMySpec.Environments,
      CodeMySpec.Files,
      CodeMySpec.Problems,
      CodeMySpec.Repo,
      CodeMySpec.StaticAnalysis,
      CodeMySpec.Tests,
      CodeMySpec.Tools,
      CodeMySpec.Users.Scope,
      CodeMySpec.Validation.Blocking
    ],
    exports: :all

  # Declared in `Environments` (a leaf) and implemented here, to avoid a cycle.
  @behaviour CodeMySpec.Environments.HarnessTransport

  require Logger

  alias CodeMySpec.Analysis.{
    Execution,
    FleetHold,
    FleetHolds,
    HarnessRegistry,
    ProjectServer,
    Reconciler,
    Run,
    Runners,
    RunsRepository
  }

  alias CodeMySpec.Users.Scope

  # `:async` (default) runs jobs through the per-copy ProjectServer.
  # `:inline` (test env) executes in the caller process: sandbox-owned DB
  # connections, deterministic ordering.
  defp mode, do: Application.get_env(:code_my_spec, :analysis_mode, :async)

  # Canonical args for a source request: bare, so every source sweeps every
  # file; a scoped sweep can only refresh part of the Problems table.
  @full_args %{
    "compiler" => [],
    "credo" => [],
    "exunit" => [],
    "spex" => []
  }

  @doc """
  Enqueue a background run for every requested source. Compile is enqueued
  first — every other source skips itself while it lands errors.

  Called by explicit analysis only: `start_analysis`, ready-for-QA
  certification and promotion. A stop never calls this.

  Each request is a source string (canonical full run) or a
  `{source, args}` tuple (e.g. credo scoped to some files). Requests with
  path-like args are `:partial`.

  Returns `%{enqueued: [source], memoized: []}` immediately; jobs run in the
  background and reconcile Problems as they land. `memoized` is always empty:
  an explicit request always runs.

  ## Options

  - `:notify` (default `true`) — push a notification when a run lands
    blocking problems (the agent may have stopped by then).
  - cassette escape hatches (`:compile_output_file`, `:exunit_output_file`,
    `:spex_output_file`, `:credo_output_file`) pass through to the runners.
  """
  @spec ensure_stale_runs(Scope.t(), [String.t() | {String.t(), [String.t()]}], keyword()) ::
          %{enqueued: [String.t()], memoized: [String.t()]}
  def ensure_stale_runs(%Scope{} = scope, requests, opts \\ []) do
    runs = plan_runs(requests)

    Enum.each(runs, fn {source, args} ->
      job = build_job(source, args, opts)
      dispatch(scope, job)
    end)

    enqueued = Enum.map(runs, &elem(&1, 0))

    if enqueued != [],
      do: Logger.info("[Analysis] enqueued: #{Enum.join(enqueued, ", ")}")

    %{enqueued: enqueued, memoized: []}
  end

  @doc """
  The runs `requests` become, compile first.

  Public so the ordering can be asserted without dispatching.
  """
  @spec plan_runs([term()]) :: list()
  def plan_runs(requests) do
    requests
    |> Enum.map(&normalize_request/1)
    |> order_compile_first()
  end

  defp normalize_request({source, args}) when is_list(args), do: {source, args}

  defp normalize_request(source) when is_binary(source),
    do: {source, Map.fetch!(@full_args, source)}

  @doc """
  Admit an analyzer run durably and return its id without waiting for execution.

  A remote harness or local analysis supervisor must exist. The ledger row is
  created before returning; admission failures reach the caller synchronously.
  """
  @spec start_run(Scope.t(), String.t(), [String.t()], keyword()) ::
          {:ok, :started | :joined | :skipped, integer()} | {:error, term()}
  def start_run(%Scope{} = scope, source, args, opts \\ []) when is_list(args) do
    # 783f3709: checked here, before anything is admitted, so a hold reaches
    # an agent already mid-run at its very next admission attempt rather than
    # only at its next turn boundary. Never touches a run already open --
    # that one finishes on its own.
    case FleetHolds.active(scope) do
      %FleetHold{} = hold ->
        {:error, {:held, hold}}

      nil ->
        job = build_job(source, args, opts)

        case remote_executor(scope) do
          {:ok, channel} ->
            dispatch_remote(scope, job, channel)

          :none ->
            start_local(scope, job, mode())
        end
    end
  end

  # `mode/0` decides, so under `:inline` a run never becomes an async server
  # that outlives its test. Answers admission, not outcome: the execution's
  # result is recorded on the run.
  defp start_local(scope, job, :inline) do
    with {:ok, run} <- open_run(scope, job) do
      _ = Execution.execute(scope, run, job.opts)
      {:ok, :started, run.id}
    end
  end

  defp start_local(scope, job, :async) do
    with {:ok, server} <- ensure_server(scope) do
      ProjectServer.ensure_run(server, scope, job)
    end
  end

  @doc """
  Run one analyzer and block until it finishes (joining an identical
  in-flight run instead of double-executing). Never memo-skips: an explicit
  call always executes — it's the escape hatch for flaky tests.

  Returns `{:ok, %Run{}}` with output/stats, or `{:error, reason}`.
  """
  @spec await_run(Scope.t(), String.t(), [String.t()], keyword()) ::
          {:ok, Run.t()} | {:error, term()}
  def await_run(%Scope{} = scope, source, args, opts \\ []) when is_list(args) do
    # 783f3709: the agent's own `mix test`/`mix spex` rewrite calls this, so
    # the same hold check as `start_run/4` belongs here too -- otherwise that
    # path would reach admission unchecked.
    case FleetHolds.active(scope) do
      %FleetHold{} = hold ->
        {:error, {:held, hold}}

      nil ->
        job = build_job(source, args, Keyword.put(opts, :notify, false))

        # Remote when a harness holds the copy, or the analyzer would run against
        # the server's disk instead of the agent's working copy.
        case remote_executor(scope) do
          {:ok, channel} -> await_remote(scope, job, channel)
          :none -> await_local(scope, job)
        end
    end
  end

  defp await_local(scope, job) do
    case mode() do
      :inline ->
        run_inline(scope, job)

      :async ->
        with {:ok, server} <- ensure_server(scope),
             {:ok, run} <- ProjectServer.await_run(server, scope, job) do
          # Reload — the task finished the row after building the reply.
          {:ok, CodeMySpec.Repo.get(Run, run.id) || run}
        end
    end
  end

  # Waits on the completion broadcast, subscribed before dispatching so a fast
  # analyzer cannot finish before the subscription lands.
  defp await_remote(scope, job, channel) do
    topic = "analysis:#{scope.active_project_id}"
    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, topic)

    try do
      case dispatch_remote(scope, job, channel) do
        {:ok, started_or_joined, run_id} when started_or_joined in [:started, :joined] ->
          wait_for_remote(scope, run_id, job.source, deadline())

        # Never dispatched — the code does not compile, so the row is already
        # closed and nothing will ever broadcast for it.
        {:ok, :skipped, run_id} ->
          {:ok, RunsRepository.get_run_in_project(scope, run_id)}

        {:error, reason} ->
          {:error, reason}
      end
    after
      Phoenix.PubSub.unsubscribe(CodeMySpec.PubSub, topic)
    end
  end

  # Matched on the run id, never on the source alone: a run that started
  # before the edit being waited on must not satisfy the wait.
  defp wait_for_remote(scope, run_id, source, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    receive do
      {:analysis, %{run_id: ^run_id, source: ^source}} ->
        {:ok, RunsRepository.get_run_in_project(scope, run_id)}

      # Another source finishing, or another checkout's run on this project.
      # Not ours; keep the original deadline rather than restarting it.
      {:analysis, _other} ->
        wait_for_remote(scope, run_id, source, deadline)
    after
      # 8db9e442: the run_id is durable on the retained row even when we give
      # up waiting on it, so a caller that hits this is never left with
      # nothing to resume or inspect with -- `=~ "harness_never_answered"`
      # still matches this tuple, inspected.
      max(remaining, 0) -> {:error, {:harness_never_answered, run_id}}
    end
  end

  defp deadline, do: System.monotonic_time(:millisecond) + remote_await_timeout()

  # 8db9e442: longer than the harness's own full round trip for a run, not
  # just its analyzer kill timeout alone -- `CmsHarness.Project.AnalysisServer`
  # only arms that kill timer once `CmsHarness.AnalysisSlots.acquire/1` grants
  # a machine-wide slot, and `acquire/1` itself waits up to its own
  # `wait_ceiling/0` first (both 30 minutes as of this writing, so a run can
  # legitimately take up to an hour and still be the harness working, not an
  # unresponsive one). Kept as an independent constant, not a call into
  # `CmsHarness` (undeclared Boundary dep, and a real deployment's harness is
  # not even the same process): if either of those two change, this needs to
  # stay ahead of their sum, not just one of them.
  defp remote_await_timeout do
    Application.get_env(:code_my_spec, :remote_await_timeout, :timer.minutes(61))
  end

  @doc """
  Record what a harness's analyzer printed.

  The other end of `dispatch_remote/3`: the diagnostics become Problems through
  `Runners.from_raw/2` and the Reconciler, as a local run's do.

  Every outcome closes the row. An unreadable payload or a tool that would not
  start fails it rather than completing it empty, because a `:completed` run
  with no problems means "looked, and it is clean".
  """
  @spec record_remote_result(Scope.t(), map()) :: {:ok, Run.t()} | {:error, term()}
  def record_remote_result(%Scope{} = scope, %{"run_id" => run_id} = payload)
      when is_integer(run_id) do
    case RunsRepository.get_running_run(scope, run_id) do
      nil ->
        {:error, :unknown_run}

      %Run{} = run ->
        run = RunsRepository.record_tree(run, Map.take(payload, ["completed_commit"]))
        result = apply_remote_result(scope, run, payload)
        announce(scope, run, result)
        result
    end
  end

  def record_remote_result(_scope, _payload), do: {:error, :invalid_result}

  @doc """
  Record the commit a harness's analyzer started on, whether the tree was
  clean, and when it began. The run may have sat in the harness's queue since
  dispatch, so this is when it actually ran.
  """
  @spec record_remote_start(Scope.t(), map()) :: {:ok, Run.t()} | {:error, :unknown_run}
  def record_remote_start(%Scope{} = scope, %{"run_id" => run_id} = payload)
      when is_integer(run_id) do
    case RunsRepository.get_running_run(scope, run_id) do
      nil ->
        {:error, :unknown_run}

      %Run{} = run ->
        {:ok,
         RunsRepository.record_tree(
           run,
           payload
           |> Map.take(["start_commit", "start_tree_dirty"])
           |> Map.put("began_at", DateTime.utc_now())
         )}
    end
  end

  def record_remote_start(_scope, _payload), do: {:error, :unknown_run}

  # Same topic and shape as `ProjectServer`'s broadcast, so subscribers cannot
  # tell which machine ran the tool.
  defp announce(scope, run, result) do
    status =
      case result do
        {:ok, %Run{status: status}} -> status
        _ -> :failed
      end

    Phoenix.PubSub.broadcast(
      CodeMySpec.PubSub,
      "analysis:#{scope.active_project_id}",
      {:analysis,
       %{
         source: run.source,
         status: status,
         run_id: run.id,
         started_at: run.started_at,
         working_copy_id: run.working_copy_id
       }}
    )

    # Not to the graph: a failed run changes nothing a requirement reads.
    :ok
  end

  @doc """
  Why a run id could not be answered, in words, for the log line.

  Diagnostics only — never control flow. Distinguishes "already closed" from
  "belongs to another checkout", which have different causes.
  """
  @spec explain_unknown_run(Scope.t(), term()) :: String.t()
  def explain_unknown_run(%Scope{} = scope, run_id) when is_integer(run_id) do
    scope
    |> RunsRepository.get_run_in_project(run_id)
    |> describe_run(scope.active_working_copy_id)
  end

  def explain_unknown_run(_scope, run_id), do: "run id is not an integer: #{inspect(run_id)}"

  defp describe_run(nil, _working_copy_id), do: "no run with that id exists in this project"

  defp describe_run(%Run{working_copy_id: owner}, working_copy_id)
       when owner != working_copy_id do
    "it belongs to working copy #{inspect(owner)}, not #{inspect(working_copy_id)}"
  end

  defp describe_run(%Run{status: :running}, _working_copy_id) do
    "it is still running, so this reply raced its own dispatch"
  end

  defp describe_run(%Run{status: status, finished_at: finished_at}, _working_copy_id) do
    "it was closed as #{status} at #{inspect(finished_at)} — most likely swept " <>
      "while the analyzer was still working"
  end

  defp apply_remote_result(scope, run, %{"status" => "ok", "result" => raw} = payload)
       when is_map(raw) do
    case Runners.from_raw(run.source, raw) do
      {:ok, result} ->
        result = note_analyzer_staleness(result, payload)
        reconcile_or_finish_tied(scope, as_executed(run, payload), result, payload["tied_to"])

      {:error, reason} ->
        Reconciler.fail(run, reason, %{output: raw["output"], exit_status: raw["exit_status"]})
        {:error, reason}
    end
  rescue
    # `from_raw/2` raises on a payload it refuses to read as clean. The run is
    # failed rather than left open, which would read as analysis pending forever.
    exception ->
      Reconciler.fail(run, Exception.message(exception))
      {:error, Exception.message(exception)}
  end

  # A scheduling refusal, not an analyzer outcome: the harness already had a
  # run queued for this source and it will answer for both.
  defp apply_remote_result(_scope, run, %{"status" => "superseded"} = payload) do
    reason = payload["error"] || "superseded by a run already queued"
    Reconciler.supersede(run, reason)
    {:error, {:superseded, reason}}
  end

  defp apply_remote_result(_scope, run, %{"status" => "error"} = payload) do
    reason = payload["error"] || "the harness reported a failure with no reason"
    Reconciler.fail(run, reason)
    {:error, reason}
  end

  defp apply_remote_result(_scope, run, payload) do
    reason = "unreadable analysis_result: #{inspect(Map.keys(payload))}"
    Reconciler.fail(run, reason)
    {:error, reason}
  end

  # `tied_to` is nil for the run the harness executed and the primary's id for
  # every request tied onto it. Only the primary reconciles; a tied run just
  # closes its row (reconciling both doubled every problem).
  #
  # A partial run that a full request tied onto ran the whole suite (the
  # harness merges a tie's args), so it is reconciled as full.
  defp as_executed(%Run{kind: :partial} = run, %{"args" => []}), do: %{run | kind: :full}
  defp as_executed(run, _payload), do: run

  defp reconcile_or_finish_tied(scope, run, result, nil),
    do: Reconciler.reconcile(scope, run, result, notify: true)

  defp reconcile_or_finish_tied(scope, run, result, tied_to) when is_integer(tied_to),
    do: Reconciler.finish_tied(scope, run, result)

  # Whether the harness ran analyzer code older than the tree it judged —
  # computed there, carried on `stats`, so the stop response can say whether
  # stopping again can help.
  defp note_analyzer_staleness(result, %{"analyzer_staleness" => note}) when is_binary(note) do
    Map.update(result, :stats, %{"analyzer_staleness" => note}, fn stats ->
      Map.put(stats || %{}, "analyzer_staleness", note)
    end)
  end

  defp note_analyzer_staleness(result, _payload), do: result

  @doc """
  Block until every in-flight run for the project has finished.

  Returns `:timeout` when the deadline passes first (default 10 minutes).
  `timeout: :infinity` waits with no deadline of its own; the harness's own
  30-minute analyzer kill bounds a stuck run.
  """
  @spec await_all(Scope.t(), keyword()) :: :ok | :timeout
  def await_all(%Scope{} = scope, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, :timer.minutes(10))
    poll_until_idle(scope, deadline_for(timeout))
  end

  defp deadline_for(:infinity), do: :infinity
  defp deadline_for(timeout), do: System.monotonic_time(:millisecond) + timeout

  @doc "Any run currently running or queued for the project?"
  @spec runs_in_flight?(Scope.t()) :: boolean()
  def runs_in_flight?(%Scope{} = scope), do: in_flight(scope) != []

  @doc """
  Sources currently running or queued.

  For a harness-served copy the ledger answers: a `:running` row is the
  server's only record of a request not yet answered. The channel closes those
  rows when it goes, and a fresh join settles any that outlived a hard kill.
  """
  @spec in_flight(Scope.t()) :: [String.t()]
  def in_flight(%Scope{} = scope) do
    case in_flight_state(scope) do
      {:running, sources} -> sources
      _ -> []
    end
  end

  @doc "Whether the scope's working copy has a run still open."
  @spec running_on?(Scope.t()) :: boolean()
  defdelegate running_on?(scope), to: RunsRepository

  @doc "Whether an agent has a run it requested still in flight on a working copy."
  @spec awaiting_runs?(Scope.t(), Ecto.UUID.t() | nil, String.t()) :: boolean()
  defdelegate awaiting_runs?(scope, working_copy_id, agent_id), to: RunsRepository

  @doc """
  Whether anything is running, nothing is, or nobody is watching.

  A local project with no entry in `Analysis.Registry` (no server started, or a
  build without the Analysis subtree) is `:untracked`: absent information, not
  idle. A harness-served copy is tracked by definition — the ledger is the
  record. See knowledge/analysis, "In-flight state".
  """
  @spec in_flight_state(Scope.t()) :: {:running, [String.t()]} | :idle | :untracked
  def in_flight_state(%Scope{} = scope) do
    case remote_executor(scope) do
      {:ok, _pid} -> sources_or_idle(RunsRepository.running_sources(scope))
      :none -> local_in_flight_state(scope)
    end
  end

  defp local_in_flight_state(%Scope{} = scope) do
    case Registry.lookup(CodeMySpec.Analysis.Registry, server_key(scope)) do
      [{pid, _}] -> pid |> ProjectServer.in_flight() |> sources_or_idle()
      [] -> :untracked
    end
  rescue
    # Registry not started (web build, or no Analysis subtree): nobody is
    # watching, which is not the same as nothing running.
    ArgumentError -> :untracked
  end

  defp sources_or_idle([]), do: :idle
  defp sources_or_idle(sources), do: {:running, sources}

  @doc """
  Where this scope's analyzers run: the harness channel holding its working
  copy, or `:none`.

  A pid, not a boolean: it is both "can an analyzer run here" and where the run
  is sent, so a run is never enqueued for a harness that has gone.
  """
  @spec remote_executor(Scope.t()) :: {:ok, pid()} | :none
  # Keyed on the working copy: each checkout has its own `_build`, and a result
  # from one says nothing about another.
  def remote_executor(%Scope{active_working_copy_id: nil}), do: :none

  def remote_executor(%Scope{active_working_copy_id: working_copy_id}) do
    case Registry.lookup(HarnessRegistry, to_string(working_copy_id)) do
      [{pid, _}] -> {:ok, pid}
      [] -> :none
    end
  rescue
    # No registry: a build that does not mount the harness channel.
    ArgumentError -> :none
  end

  @doc """
  Ask a harness to perform a filesystem operation on its own working copy.

  The transport behind `Environments.Harness`, reads and writes both: the
  server holds no checkout. Addressed by working copy id through the same
  registry `remote_executor/1` uses.

  Errors are `{:error, {tag, details}}`, never a bare atom, and never
  `:no_environment` (that means no working copy; these mean one that could not
  be reached):

    * `:harness_not_registered` — nothing registered under that id; the harness
      has not joined since this server started. Restarting it rejoins.
    * `:harness_timeout` — registered, accepted, did not answer. Carries
      `elapsed_ms` and `limit_ms`.
    * `:harness_gone` — the serving process died before answering. Carries
      `elapsed_ms` and `down`. For an op that restarts the application,
      `{:shutdown, :draining}` is what success looks like;
      `Promotion.restart_acknowledgement_lost?/1` decides that.
    * `:harness_self_call` — the caller is the channel process: a wiring bug
      in this server.
    * `:harness_registry_down` — the registry itself is not running.

  See knowledge/analysis, "Harness filesystem requests".
  """
  @impl CodeMySpec.Environments.HarnessTransport
  @spec harness_fs_request(String.t(), String.t(), map(), timeout()) ::
          {:ok, term()} | :ok | {:error, term()}
  def harness_fs_request(working_copy_id, op, payload, timeout) do
    started = System.monotonic_time(:millisecond)

    # Explicit `try`, so the catch clauses can see `started`.
    try do
      case Registry.lookup(HarnessRegistry, to_string(working_copy_id)) do
        [{pid, _}] ->
          GenServer.call(pid, {:fs_request, op, payload}, timeout + call_grace_ms())

        [] ->
          Logger.warning(
            "[Analysis] #{op} for harness #{working_copy_id}: nothing registered under that id. " <>
              "The harness has not joined the channel since this server started — its own " <>
              "/health will still say connected, because that is about its socket rather " <>
              "than about whether the server can address it. Restarting the harness rejoins."
          )

          {:error, {:harness_not_registered, %{working_copy_id: working_copy_id, op: op}}}
      end
    rescue
      ArgumentError ->
        Logger.warning(
          "[Analysis] #{op} for harness #{working_copy_id}: HarnessRegistry is not running"
        )

        {:error, {:harness_registry_down, %{working_copy_id: working_copy_id, op: op}}}
    catch
      # OTP exits a self-call at once with `{:calling_self, _}`; not a timeout.
      :exit, {:calling_self, _} = reason ->
        Logger.warning(
          "[Analysis] #{op} for harness #{working_copy_id} was called from the channel process " <>
            "itself: #{inspect(reason, limit: 3)}. Nothing is wrong with the harness — this " <>
            "is a reconcile reaching for a file from inside the process that would serve it."
        )

        {:error, {:harness_self_call, %{working_copy_id: working_copy_id, op: op}}}

      :exit, {:timeout, _} = reason ->
        elapsed = System.monotonic_time(:millisecond) - started
        limit = timeout + call_grace_ms()

        Logger.warning(
          "[Analysis] #{op} for harness #{working_copy_id} did not complete after " <>
            "#{elapsed}ms (limit #{limit}ms): #{inspect(reason, limit: 5)}. The harness is " <>
            "registered, so this is not a connection problem — it accepted the request and " <>
            "did not answer."
        )

        {:error,
         {:harness_timeout,
          %{working_copy_id: working_copy_id, op: op, elapsed_ms: elapsed, limit_ms: limit}}}

      # A callee that died, not one that hung: `GenServer.call/3` exits with the
      # callee's reason. `limit_ms` is omitted so it never reads as a timeout.
      :exit, reason ->
        elapsed = System.monotonic_time(:millisecond) - started
        down = if is_tuple(reason) and tuple_size(reason) > 0, do: elem(reason, 0), else: reason

        Logger.warning(
          "[Analysis] #{op} for harness #{working_copy_id}: the channel went down after " <>
            "#{elapsed}ms with #{inspect(down, limit: 5)}. It was registered and took the " <>
            "request, so this is not a registration problem either — the process serving it " <>
            "died before answering. If the op was one that restarts the application, this is " <>
            "what success looks like from here."
        )

        {:error,
         {:harness_gone,
          %{working_copy_id: working_copy_id, op: op, elapsed_ms: elapsed, down: down}}}
    end
  end

  @doc """
  Ask the harness holding this working copy to rescan it and re-send its
  manifest.

  The server cannot walk a remote checkout, and the harness stops watching
  while disconnected, so this is the lever for a graph believed stale.
  Fire-and-forget: the manifest lands on the ordinary `observations` path.
  Returns only whether the request was delivered.
  """
  @spec request_rescan(Scope.t()) :: :ok | {:error, {atom(), map()}}
  def request_rescan(%Scope{active_working_copy_id: nil}),
    do: {:error, {:harness_not_registered, %{working_copy_id: nil}}}

  def request_rescan(%Scope{active_working_copy_id: working_copy_id}) do
    case remote_executor(%Scope{active_working_copy_id: working_copy_id}) do
      {:ok, channel} ->
        send(channel, :rescan)
        :ok

      :none ->
        Logger.warning(
          "[Analysis] rescan for harness #{working_copy_id}: nothing registered under that id. " <>
            "The harness has not joined the channel since this server started; its own " <>
            "/health will still say connected, because that is about its socket rather " <>
            "than about whether the server can address it."
        )

        {:error, {:harness_not_registered, %{working_copy_id: working_copy_id}}}
    end
  end

  @doc """
  Stop the runs a working copy's harness holds, running or queued.

  Each is answered as superseded with `reason`, so its row closes as a run that
  did not finish rather than a failure. For a copy whose runs belong to work
  that has ended, like a promotion batch that left the gate. Nothing registered
  for the copy has nothing to stop.
  """
  @spec cancel_on(Scope.t(), String.t()) :: :ok | {:error, term()}
  def cancel_on(%Scope{active_working_copy_id: nil}, _reason), do: :ok

  def cancel_on(%Scope{active_working_copy_id: working_copy_id}, reason)
      when is_binary(reason) do
    case remote_executor(%Scope{active_working_copy_id: working_copy_id}) do
      {:ok, channel} ->
        send(channel, {:cancel_analysis, reason})
        :ok

      :none ->
        {:error, {:harness_not_registered, %{working_copy_id: working_copy_id}}}
    end
  end

  @doc """
  Close out every `:running` run for the working copy as failed orphans.

  Called when a harness's channel goes and again when one joins: the queue that
  would answer those runs is gone, and left open they read as analysis pending
  forever.
  """
  @spec fail_in_flight(Scope.t(), term()) :: {:ok, non_neg_integer()}
  def fail_in_flight(%Scope{} = scope, reason), do: fail_in_flight(scope, reason, [])

  @doc """
  As `fail_in_flight/2`, sparing the runs the harness says it is still working
  on.

  `claimed` comes from the harness's join payload. It is unverifiable, but a
  wrong claim costs one run staying `:running` until the next reconnect.
  """
  @spec fail_in_flight(Scope.t(), term(), [integer()]) :: {:ok, non_neg_integer()}
  # The requester is not told here: these are orphans the next join settles
  # (`resume_orphaned/2`), and the agent's transport is the harness that just
  # went away.
  def fail_in_flight(%Scope{} = scope, reason, claimed) do
    {:ok, failed} = RunsRepository.fail_running(scope, reason, claimed)
    count = length(failed)

    if count > 0 do
      Logger.warning(
        "[Analysis] closed #{count} stranded run(s): #{inspect(reason)}" <>
          claimed_suffix(claimed) <> " — the next join for this copy settles them"
      )
    end

    {:ok, count}
  end

  @doc """
  Close every run a previous server process left `:running`, as orphans the
  next join for each copy settles (`resume_orphaned/2`).
  """
  @spec fail_stranded_runs() :: {:ok, non_neg_integer()}
  def fail_stranded_runs do
    {:ok, failed} = RunsRepository.fail_stranded_runs()
    {:ok, length(failed)}
  end

  # A run killed on every attempt is killing its harness or riding a restart
  # storm; running it again will not help.
  @max_redispatches 3

  @doc """
  Settle the runs this copy's harness took with it when it went, now that one
  has joined again.

  A promote restarts the server and the harness, which fails every copy's
  in-flight runs (`fail_in_flight/3`, `fail_stranded_runs/0`). Those are not
  answers.

  Each orphan, oldest first:

    * claimed by the harness in `claimed` — it is still executing it, so the
      row goes back to `:running` and its result is accepted when it lands;
    * requested through `start_analysis`, whose answer is still owed —
      started again at the current tree, carrying the same requester, so the
      answer reaches whoever asked;
    * killed #{@max_redispatches} times over — reported to its requester as
      failed instead;
    * anything else — left closed. Nothing starts analysis on its own.

  A run that failed on its own is never an orphan: only the two sweeps above
  mark one, so an analyzer error is not re-run.
  """
  @spec resume_orphaned(Scope.t(), [integer()]) :: :ok
  def resume_orphaned(%Scope{} = scope, claimed) do
    scope
    |> RunsRepository.unsettled_orphans()
    |> Enum.each(&resume_orphan(scope, &1, claimed))
  end

  defp resume_orphan(scope, run, claimed) do
    cond do
      run.id in claimed -> reopen_orphan(run)
      not answer_owed?(run) -> RunsRepository.settle_orphan(run, "nobody waiting")
      redispatches(run) >= @max_redispatches -> give_up_on_orphan(run)
      true -> rerun_orphan(scope, run)
    end
  end

  defp reopen_orphan(run) do
    with :ok <- RunsRepository.reopen_orphan(run) do
      Logger.info(
        "[Analysis] run #{run.id} (#{run.source}) reopened — the harness still holds it"
      )
    end
  end

  defp rerun_orphan(scope, run) do
    with :ok <- RunsRepository.settle_orphan(run, "run again") do
      requested_by =
        Map.merge(run.requested_by, %{
          "rerun_of" => run.id,
          "redispatches" => redispatches(run) + 1
        })

      case start_run(scope, run.source, orphan_args(run), requested_by: requested_by) do
        {:ok, outcome, id} ->
          Logger.info(
            "[Analysis] run #{run.id} (#{run.source}) was killed by its harness going away; " <>
              "#{outcome} as run #{id} for #{inspect(run.requested_by)}"
          )

        {:error, reason} ->
          Reconciler.announce_failed(
            run,
            "#{orphan_error(run)} — and running it again failed: #{inspect(reason)}"
          )
      end
    end
  end

  defp give_up_on_orphan(run) do
    with :ok <- RunsRepository.settle_orphan(run, "gave up") do
      Reconciler.announce_failed(
        run,
        "#{orphan_error(run)} — its harness went away on each of " <>
          "#{redispatches(run) + 1} attempts, so it is not being run again automatically"
      )
    end
  end

  # Owed when `start_analysis` recorded an `agent_id` (it answers later) or an
  # agent waits on the run (`wait_on_running_at_commit/4`). A blocking
  # `await_run/4` already answered its caller with an error, which asks again.
  defp answer_owed?(%Run{requested_by: %{} = by}),
    do: Map.has_key?(by, "agent_id") or match?([_ | _], by["waiters"])

  defp answer_owed?(_run), do: false

  defp redispatches(%Run{requested_by: %{"redispatches" => n}}) when is_integer(n), do: n
  defp redispatches(_run), do: 0

  defp orphan_args(%Run{args: %{"args" => args}}) when is_list(args), do: args
  defp orphan_args(_run), do: []

  defp orphan_error(%Run{stats: %{"error" => error}}) when is_binary(error), do: error
  defp orphan_error(_run), do: "its harness went away"

  defp claimed_suffix([]), do: ""

  defp claimed_suffix(claimed),
    do: " (spared #{length(claimed)} the harness still holds: #{inspect(claimed)})"

  @doc """
  Per-source gauge state for the UI and the wait summary.

  Returns `%{source => %{state, run}}` where state is `:running`, `:completed`
  (the latest full run completed), `:failed` (it crashed or was skipped), or
  `:none` (no full run yet). Nothing here says whether a run is current; the
  promote gate is keyed on the commit.
  """
  @spec status(Scope.t()) :: %{String.t() => %{state: atom(), run: Run.t() | nil}}
  def status(%Scope{} = scope) do
    latest = RunsRepository.latest_full_runs(scope)
    running = in_flight(scope)

    Map.new(Run.sources(), fn source ->
      state =
        cond do
          source in running -> :running
          match?(%Run{status: :completed}, latest[source]) -> :completed
          match?(%Run{status: :failed}, latest[source]) -> :failed
          true -> :none
        end

      {source, %{state: state, run: latest[source]}}
    end)
  end

  @doc """
  The latest completed run of `source`, however old, or nil.

  Anything reporting about the answer (its age, its commit) must read this
  run, not `status/1`'s latest, which may be a newer failure.
  """
  @spec latest_answer(Scope.t(), String.t()) :: Run.t() | nil
  def latest_answer(%Scope{} = scope, source),
    do: RunsRepository.latest_completed_run(scope, source)

  @doc """
  How many full runs of `source` on this copy failed to run at `commit` (or,
  opened since `since`, before saying where they started); runs orphaned by
  their harness going away are not counted.
  """
  @spec failed_at_commit(Scope.t(), String.t(), String.t(), DateTime.t()) :: non_neg_integer()
  defdelegate failed_at_commit(scope, source, commit, since), to: RunsRepository

  @doc "Find a retained run for output retrieval, restricted to the selected working copy."
  @spec output_run(Scope.t(), {:id, integer()} | {:source, String.t()}) :: Run.t() | nil
  defdelegate output_run(scope, selector), to: RunsRepository

  @doc "The latest finished full run of `source` on this copy, a failure included, or nil."
  @spec latest_run(Scope.t(), String.t()) :: Run.t() | nil
  def latest_run(%Scope{} = scope, source), do: RunsRepository.latest_full_run(scope, source)

  @doc "Whether `source` has a completed full run on this copy — anything that answers for it."
  @spec answered?(Scope.t(), String.t()) :: boolean()
  defdelegate answered?(scope, source), to: RunsRepository

  @doc """
  `source`'s latest completed run on this copy when it answers for `commit`
  (`Run.at_commit?/2`), else nil. The latest only: the source's recorded
  problems are that run's, so an older run at `commit` behind it says nothing
  about them.
  """
  @spec answer_at_commit(Scope.t(), String.t(), String.t()) :: Run.t() | nil
  def answer_at_commit(%Scope{} = scope, source, commit) do
    run = RunsRepository.latest_completed_run(scope, source)
    if Run.at_commit?(run, commit), do: run
  end

  @doc """
  Whether a full run of `source` still running on this copy will answer for
  `commit`: started there on a clean tree, or queued and not started yet.
  """
  @spec running_at_commit?(Scope.t(), String.t(), String.t()) :: boolean()
  def running_at_commit?(%Scope{} = scope, source, commit) do
    scope
    |> RunsRepository.running_full_runs(source)
    |> Enum.any?(fn run ->
      is_nil(run.start_commit) or (run.start_commit == commit and run.start_tree_dirty == false)
    end)
  end

  @doc """
  `running_at_commit?/3`, and the agent waiting on it: `agent_id` is told when
  the run lands and is not nudged meanwhile, whoever started it.
  """
  @spec wait_on_running_at_commit(Scope.t(), String.t(), String.t(), String.t()) :: boolean()
  defdelegate wait_on_running_at_commit(scope, source, commit, agent_id), to: RunsRepository

  # -- Internals --

  # Compile first: it's the cheapest signal and every other source
  # short-circuits on its errors.
  defp order_compile_first(requests) do
    Enum.sort_by(requests, fn {source, _args} -> source != "compiler" end)
  end

  defp build_job(source, args, opts) do
    %{
      source: source,
      args: args,
      kind: kind_for(args),
      # Carried as a value, not read from `Logger.metadata()`: callers hand the
      # job to unlinked Tasks that start without it.
      requested_by: Keyword.get(opts, :requested_by),
      opts: runner_opt_passthrough(opts) ++ [notify: Keyword.get(opts, :notify, true)]
    }
  end

  # Path-like args mean the caller targeted specific files, so the run is
  # `:partial`: it never satisfies freshness and never replaces Problems.
  defp kind_for(args) do
    if Enum.any?(args, &(not String.starts_with?(&1, "-"))), do: :partial, else: :full
  end

  @passthrough_opts [
    :compile_output_file,
    :credo_output_file,
    :exunit_output_file,
    :spex_output_file
  ]

  defp runner_opt_passthrough(opts), do: Keyword.take(opts, @passthrough_opts)

  defp dispatch(scope, job) do
    case remote_executor(scope) do
      {:ok, channel} -> dispatch_remote(scope, job, channel)
      :none -> dispatch_local(scope, job)
    end
  end

  defp dispatch_local(scope, job) do
    case mode() do
      :inline ->
        run_inline(scope, job)

      :async ->
        {:ok, server} = ensure_server(scope)
        ProjectServer.ensure_run(server, scope, job)
    end
  end

  # The row is opened first so a request the harness never answers stays
  # traceable (failed when its channel closes). A busy source is sent anyway:
  # the harness serialises and queues it behind itself.
  # See knowledge/analysis, "Where a run executes".
  defp dispatch_remote(scope, job, channel) do
    case joinable_run(scope, job) do
      %Run{} = run -> join_remote(job, channel, run)
      nil -> open_remote(scope, job, channel)
    end
  end

  # A harness holds at most two entries per source (executing and queued) and
  # ties further requests onto the queued one. So once two full rows are open,
  # a new request joins the newest instead of opening another row. Still sent,
  # under that id, so a harness that lost it (a restart) queues it afresh.
  defp joinable_run(scope, %{kind: :full, source: source}) do
    case RunsRepository.running_full_runs(scope, source) do
      [newest, _older | _] -> newest
      _ -> nil
    end
  end

  defp joinable_run(_scope, _job), do: nil

  defp join_remote(job, channel, run) do
    Logger.info("[Analysis] #{job.source} joined run #{run.id} already queued on the harness")

    send(
      channel,
      {:run_analysis, [%{"run_id" => run.id, "source" => job.source, "args" => job.args}]}
    )

    {:ok, :joined, run.id}
  end

  defp open_remote(scope, job, channel) do
    case RunsRepository.start_run(scope, %{
           source: job.source,
           kind: job.kind,
           args: %{"args" => job.args},
           requested_by: job.requested_by
         }) do
      {:ok, run} -> send_or_skip(scope, job, channel, run)
      {:error, reason} -> {:error, reason}
    end
  end

  # The same compile-error skip `Execution.execute/3` applies locally, decided
  # here because the executing machine is not this one.
  defp send_or_skip(scope, job, channel, run) do
    if Execution.skip_for_compile_errors?(scope, run) do
      Reconciler.fail(run, :skipped_compile_errors)
      {:ok, :skipped, run.id}
    else
      send(
        channel,
        {:run_analysis, [%{"run_id" => run.id, "source" => job.source, "args" => job.args}]}
      )

      {:ok, :started, run.id}
    end
  end

  defp run_inline(scope, job) do
    with {:ok, run} <- open_run(scope, job), do: Execution.execute(scope, run, job.opts)
  end

  defp open_run(scope, job) do
    RunsRepository.start_run(scope, %{
      source: job.source,
      kind: job.kind,
      args: %{"args" => job.args},
      requested_by: job.requested_by
    })
  end

  # Keyed on the working copy (it owns the build tree the queue protects),
  # falling back to the project when no copy is bound.
  @doc """
  Public only so the property that matters can be asserted directly: two
  checkouts of one project get different queues, the same checkout gets one.
  """
  def server_key(%Scope{active_working_copy_id: working_copy_id})
      when not is_nil(working_copy_id),
      do: {:harness, to_string(working_copy_id)}

  def server_key(%Scope{active_project_id: project_id}), do: {:project, project_id}

  defp ensure_server(%Scope{active_project_id: project_id} = scope) do
    case Process.whereis(CodeMySpec.Analysis.ServerSupervisor) do
      nil ->
        {:error, :no_executor}

      supervisor ->
        case DynamicSupervisor.start_child(
               supervisor,
               {ProjectServer, {server_key(scope), project_id}}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # `:timeout` is distinct from `:ok`, so "finished" and "gave up waiting"
  # never read the same.
  defp poll_until_idle(scope, deadline) do
    cond do
      not runs_in_flight?(scope) ->
        :ok

      deadline != :infinity and System.monotonic_time(:millisecond) >= deadline ->
        :timeout

      true ->
        Process.sleep(500)
        poll_until_idle(scope, deadline)
    end
  end

  # Grace added to the caller's timeout so "slow" and "gone" stay
  # distinguishable; configurable for tests.
  defp call_grace_ms, do: Application.get_env(:code_my_spec, :call_grace_ms, 5_000)
end
