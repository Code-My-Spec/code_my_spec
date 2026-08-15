defmodule CodeMySpec.Analysis do
  @moduledoc """
  The analysis run service: what ran, when, over which inputs — and the
  single execution path shared by the stop hook and model-invoked test runs.

  Analyzer sources (`compiler`, `credo`, `exunit`, `spex`) execute as
  supervised background jobs, serialized per project, with results reconciled
  into Problems and recorded in the `analysis_runs` ledger. A completed
  `:full` run whose input fingerprint matches the current Files state means
  the persisted Problems for that source are current — nothing re-runs on
  unchanged code.

  Entry points:

  - `ensure_stale_runs/3` — stop hook: enqueue whatever's stale, return
    immediately.
  - `await_run/4` — model-invoked (`mix test` rewrite) and MCP callers:
    join-or-start, block until finished, get the run back with output.
  - `runs_in_flight?/1`, `status/1` — decision + UI gauge reads.

  ## Two places a run can execute

  Deciding what is stale is a database question; running `mix` is a disk one,
  and since the light harness those are on different machines. So a run is
  dispatched one of two ways:

  - **Locally**, through the per-project `ProjectServer` — the `cms server`
    process, which has the working copy.
  - **To a harness**, when one holds this project's channel. The row is opened
    here, the tool runs there, and the result comes back as `analysis_result`
    for `Runners.from_raw/2` and the Reconciler.

  `HarnessRegistry` is what decides, and its answer is a live process rather
  than a stored flag: a harness that goes away stops being an executor at the
  moment its channel closes, not at the moment somebody notices.
  """

  # The transport `Environments.Harness` reaches a working copy over. Declared
  # there and wired here, because `Environments` is a leaf that everything
  # depends on and cannot name this module without closing a cycle.
  @behaviour CodeMySpec.Environments.HarnessTransport

  require Logger

  alias CodeMySpec.Analysis.{
    Execution,
    Fingerprint,
    HarnessRegistry,
    ProjectServer,
    Reconciler,
    Run,
    Runners,
    RunsRepository
  }

  alias CodeMySpec.Users.Scope

  # `:async` (default) runs jobs through the per-project ProjectServer —
  # supervised background tasks, single-flight, survives HTTP disconnects.
  # `:inline` (test env) executes in the caller process: sandbox-owned DB
  # connections, deterministic ordering, old synchronous stop semantics.
  defp mode, do: Application.get_env(:code_my_spec, :analysis_mode, :async)

  # Canonical args for a stop-hook run: bare, so every source sweeps every
  # file. Analysis is async and its results surface on the next stop, so there
  # is nothing to gain from narrowing the work — and plenty to lose, since a
  # scoped sweep can only ever refresh part of the Problems table.
  #
  # Model-invoked runs (`await_run/4`) still carry the caller's args and are
  # classified `:partial` by `kind_for/1`; only the runs enqueued from here
  # are guaranteed full.
  @full_args %{
    "compiler" => [],
    "credo" => [],
    "exunit" => [],
    "spex" => []
  }

  @doc """
  Enqueue background runs for every requested source that needs one. Compile
  is enqueued first — every other source skips itself while it lands errors.

  Each request is a source string (canonical full run) or a
  `{source, args}` tuple (e.g. credo scoped to the turn's changed files).
  Requests with path-like args are `:partial` — they always enqueue (a scoped
  run is never fresh-making, so there's nothing to memoize against). Full
  requests are memo-skipped when a completed run matches the current input
  fingerprint.

  Returns `%{enqueued: [source], memoized: [source]}` immediately; jobs run
  in the background and reconcile Problems as they land.

  ## Options

  - `:notify` (default `true`) — push a notification when a run lands
    blocking problems (the agent may have stopped by then).
  - `:only_failed` (default `false`) — enqueue only sources whose latest run
    `:failed` (crash/timeout/superseded recovery). Used by no-changed-files
    stops so they stay quiet unless there's something to heal.
  - cassette escape hatches (`:compile_output_file`, `:exunit_output_file`,
    `:spex_output_file`, `:credo_output_file`) pass through to the runners.
  """
  @spec ensure_stale_runs(Scope.t(), [String.t() | {String.t(), [String.t()]}], keyword()) ::
          %{enqueued: [String.t()], memoized: [String.t()]}
  def ensure_stale_runs(%Scope{} = scope, requests, opts \\ []) do
    fingerprints = Fingerprint.current(scope)
    latest = RunsRepository.latest_full_runs(scope)
    only_failed = Keyword.get(opts, :only_failed, false)

    {stale, memoized} = plan_runs(requests, fingerprints, latest, only_failed)

    Enum.each(stale, fn {source, args} ->
      job = build_job(source, args, fingerprints[source], opts)
      dispatch(scope, job)
    end)

    stale_sources = Enum.map(stale, &elem(&1, 0))
    memoized_sources = Enum.map(memoized, &elem(&1, 0))

    if stale_sources != [],
      do: Logger.info("[Analysis] enqueued: #{Enum.join(stale_sources, ", ")}")

    if memoized_sources != [],
      do: Logger.info("[Analysis] skipped (current): #{Enum.join(memoized_sources, ", ")}")

    %{enqueued: stale_sources, memoized: memoized_sources}
  end

  @doc false
  # Which of `requests` need running, split from those that do not.
  #
  # Public so the property that matters can be asserted without dispatching:
  # what this decides must agree with `fresh_sources/2`. They did not, and the
  # disagreement was a livelock — see `needs_run?/5`.
  @spec plan_runs([term()], map(), map(), boolean()) :: {list(), list()}
  def plan_runs(requests, fingerprints, latest, only_failed) do
    requests
    |> Enum.map(&normalize_request/1)
    |> order_compile_first()
    |> Enum.split_with(fn {source, args} ->
      needs_run?(source, args, fingerprints, latest, only_failed)
    end)
  end

  defp normalize_request({source, args}) when is_list(args), do: {source, args}

  defp normalize_request(source) when is_binary(source),
    do: {source, Map.fetch!(@full_args, source)}

  # A stop with changed files re-runs everything. The old fingerprint memo
  # skipped sources whose inputs hadn't moved, which saved little (the work is
  # async and off the critical path) and cost a lot: a skipped source left
  # last run's Problems in place with no run to explain them.
  #
  # `only_failed` survives because it is a different question — a stop with NO
  # changed files stays quiet entirely, re-enqueuing only sources whose last
  # run crashed or timed out.
  # On a quiet stop, compiler also re-runs when another source was skipped
  # *because of* compiler errors — only a compiler run can clear them.
  #
  # Without this the pipeline deadlocks: a stale compiler error makes exunit
  # skip, a skipped run finishes `:failed` (never `:completed`), `only_failed`
  # re-enqueues exunit but not compiler, so nothing can clear the error.
  # exunit re-runs and re-skips on every stop while `tests_passing` waits
  # forever for a completed run — even though `mix test` passes clean by hand.
  #
  # Scoped to the skip case on purpose: a quiet stop with nothing skipped must
  # still block on a genuinely outstanding compile error without re-running
  # anything (criterion 6077).
  # A source that has never run is stale, not current.
  #
  # `only_failed` asks for "re-run what broke", and a missing run matched
  # neither the failed clause nor anything else — so a source with no run was
  # treated as up to date and skipped, forever. It could not bootstrap: no run
  # meant no enqueue, and no enqueue meant no run.
  #
  # compiler and credo were caught by it on a real project. Nothing errored;
  # `tests_passing` simply never went green, which blocked every story's
  # qa_complete, which emptied next_actionable, which told an unattended agent
  # there was nothing left to do while ten stories sat unQA'd. `stale?/3`
  # already got this right with its `_ -> true`.
  # `only_failed` meant "the latest run completed, so there is nothing to redo".
  # Status is not evidence about the tree. A run can have completed perfectly
  # against a tree that has since moved, which is exactly the state after the
  # agent fixes the finding it was blocked on — and `fresh_sources/2`, which the
  # stop hook uses, reads the fingerprint and calls that stale.
  #
  # So both were reachable at once and contradicted each other:
  #
  #     [Analysis] skipped (current): compiler, credo, exunit, spex
  #     credo (1) — stale, last ran 19m ago … A rerun is in flight now (credo)
  #
  # Nothing was in flight, the timestamp never moved, and the hook's advice —
  # stop again and let the rerun replace these — could not succeed. Following it
  # loops; the alternative is re-editing code that is already correct
  # (`1f60a145`).
  #
  # `stale?/3` is what `status/1` already uses, so the two answers now come from
  # one comparison. `only_failed` keeps its meaning — do not redo work for an
  # unchanged tree — and loses the part that was never true, that an unchanged
  # status implies an unchanged tree.
  defp needs_run?("compiler", _args, fingerprints, latest, true) do
    stale?("compiler", fingerprints, latest) or
      Enum.any?(latest, fn {_source, run} -> skipped_for_compile_errors?(run) end)
  end

  defp needs_run?(source, _args, fingerprints, latest, true),
    do: stale?(source, fingerprints, latest)

  defp needs_run?(_source, _args, _fingerprints, _latest, _only_failed), do: true

  # `Reconciler.fail/2` stamps the reason into `stats["error"]`.
  defp skipped_for_compile_errors?(%Run{status: :failed, stats: %{"error" => err}})
       when is_binary(err),
       do: String.contains?(err, "skipped_compile_errors")

  defp skipped_for_compile_errors?(_run), do: false

  @doc """
  Run one analyzer and block until it finishes (joining an identical
  in-flight run instead of double-executing). Never memo-skips: an explicit
  call always executes — it's the escape hatch for flaky tests.

  Returns `{:ok, %Run{}}` with output/stats, or `{:error, reason}`.
  """
  @spec await_run(Scope.t(), String.t(), [String.t()], keyword()) ::
          {:ok, Run.t()} | {:error, term()}
  def await_run(%Scope{} = scope, source, args, opts \\ []) when is_list(args) do
    fingerprint = Fingerprint.current(scope, source)
    job = build_job(source, args, fingerprint, Keyword.put(opts, :notify, false))

    # `dispatch/2` has always chosen between here and the harness; this did not,
    # and ran everything locally. On a light harness that means the analyzer runs
    # against the *server's* disk rather than the working copy the agent is
    # editing — and on a developer machine where both are the same box, it does
    # so convincingly.
    case remote_executor(scope) do
      {:ok, channel} -> await_remote(scope, job, channel)
      :none -> await_local(scope, job)
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

  # The run is opened here, executed on the machine with the disk, and closed
  # when its result comes back through `record_remote_result/2` — three
  # processes and two network hops between the request and the answer. So the
  # caller waits on the completion broadcast rather than on a return value.
  #
  # Subscribed *before* dispatching, deliberately: a fast analyzer can finish
  # before a subscribe placed afterwards takes effect, and the symptom of that
  # race is a run that completed normally reported to the agent as a timeout.
  defp await_remote(scope, job, channel) do
    topic = "analysis:#{scope.active_project_id}"
    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, topic)

    try do
      case dispatch_remote(scope, job, channel) do
        {:ok, :started, run_id} ->
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

  # Matched on the run id, never on the source alone.
  #
  # There used to be an `is_nil(run_id)` escape here, for the caller that had
  # joined an in-flight run and so had no id of its own. That caller is gone
  # (`cc1016a8` — the join was a silent drop), and with it the only reason to
  # accept "some run of this source finished". Keeping it would mean a sweep
  # could be satisfied by a run that started before the edit it is waiting on,
  # which is the same wrong answer by a shorter route.
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
      max(remaining, 0) -> {:error, :harness_never_answered}
    end
  end

  defp deadline, do: System.monotonic_time(:millisecond) + remote_await_timeout()

  # Longer than the harness's own analyzer timeout, so a run it kills is
  # reported as the failure it is rather than as this giving up first — two
  # different faults that would otherwise be told to the agent identically.
  defp remote_await_timeout do
    Application.get_env(:code_my_spec, :remote_await_timeout, :timer.minutes(31))
  end

  @doc """
  Record what a harness's analyzer printed.

  The other end of `dispatch_remote/3`: the run row is already open, the tool
  has run on the machine with the disk, and this is where the diagnostics become
  Problems — through `Runners.from_raw/2`, the same conversion a local run goes
  through, and then the same Reconciler.

  Every outcome closes the row. An unreadable payload and a tool that would not
  start both `fail` it rather than completing it empty, because a `:completed`
  run with no problems is how this server says "looked, and it is clean".
  """
  @spec record_remote_result(Scope.t(), map()) :: {:ok, Run.t()} | {:error, term()}
  def record_remote_result(%Scope{} = scope, %{"run_id" => run_id} = payload)
      when is_integer(run_id) do
    case RunsRepository.get_running_run(scope, run_id) do
      nil ->
        {:error, :unknown_run}

      %Run{} = run ->
        result = apply_remote_result(scope, run, payload)
        announce(scope, run, result)
        result
    end
  end

  def record_remote_result(_scope, _payload), do: {:error, :invalid_result}

  # The local queue broadcasts every run it finishes; this path never did,
  # because until `await_run/4` could dispatch remotely nothing was listening.
  # Same topic and shape as `ProjectServer`'s, so a subscriber cannot tell —
  # and should not be able to tell — which machine ran the tool.
  defp announce(scope, run, result) do
    status =
      case result do
        {:ok, %Run{status: status}} -> status
        _ -> :failed
      end

    Phoenix.PubSub.broadcast(
      CodeMySpec.PubSub,
      "analysis:#{scope.active_project_id}",
      {:analysis, %{source: run.source, status: status, run_id: run.id}}
    )
  end

  @doc """
  Why a run id could not be answered, in words, for the log line.

  Diagnostics only — never control flow. `unknown_run` used to be reported
  without saying which run, whose, or what state it was actually in, so the
  only way to tell "already closed" from "belongs to another checkout" was to
  read the query. Those two have completely different causes and the same
  message, which is how a total failure (285 results sent, 0 accepted) stayed
  invisible for a day.
  """
  @spec explain_unknown_run(Scope.t(), term()) :: String.t()
  def explain_unknown_run(%Scope{} = scope, run_id) when is_integer(run_id) do
    scope
    |> RunsRepository.get_run_in_project(run_id)
    |> describe_run(scope.active_harness_id)
  end

  def explain_unknown_run(_scope, run_id), do: "run id is not an integer: #{inspect(run_id)}"

  defp describe_run(nil, _harness_id), do: "no run with that id exists in this project"

  defp describe_run(%Run{harness_id: owner}, harness_id) when owner != harness_id do
    "it belongs to working copy #{inspect(owner)}, not #{inspect(harness_id)}"
  end

  defp describe_run(%Run{status: :running}, _harness_id) do
    "it is still running, so this reply raced its own dispatch"
  end

  defp describe_run(%Run{status: status, finished_at: finished_at}, _harness_id) do
    "it was closed as #{status} at #{inspect(finished_at)} — most likely swept " <>
      "while the analyzer was still working"
  end

  defp apply_remote_result(scope, run, %{"status" => "ok", "result" => raw}) when is_map(raw) do
    case Runners.from_raw(run.source, raw) do
      {:ok, result} ->
        Reconciler.reconcile(scope, run, result, notify: true)

      {:error, reason} ->
        Reconciler.fail(run, reason)
        {:error, reason}
    end
  rescue
    # `from_raw/2` raises on a payload it refuses to read as clean. The run is
    # failed rather than left open, so the next stop re-enqueues it instead of
    # reporting analysis pending forever.
    exception ->
      Reconciler.fail(run, Exception.message(exception))
      {:error, Exception.message(exception)}
  end

  # A scheduling refusal, not an analyzer outcome: the harness already had a run
  # queued for this source and it will answer for both. Closed so the row does
  # not sit `:running` forever, and closed as its own thing so nothing reads it
  # as an analyzer that died.
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

  @doc "Block until every in-flight run for the project has finished."
  @spec await_all(Scope.t(), keyword()) :: :ok | :timeout
  def await_all(%Scope{} = scope, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, :timer.minutes(10))
    deadline = System.monotonic_time(:millisecond) + timeout
    poll_until_idle(scope, deadline)
  end

  @doc "Any run currently running or queued for the project?"
  @spec runs_in_flight?(Scope.t()) :: boolean()
  def runs_in_flight?(%Scope{} = scope), do: in_flight(scope) != []

  @doc """
  Sources currently running or queued.

  For a harness-served project the ledger is the answer: the queue is on the
  other machine, and a `:running` row is the server's only record that it asked
  for something and has not been told the outcome. Those rows cannot strand —
  the channel closes them when it goes, and a fresh join closes any that
  outlived a hard kill.
  """
  @spec in_flight(Scope.t()) :: [String.t()]
  def in_flight(%Scope{} = scope) do
    case in_flight_state(scope) do
      {:running, sources} -> sources
      _ -> []
    end
  end

  @doc """
  When each in-flight source started, where that is knowable.

  Only the ledger records a start time, so this answers `%{}` for a locally
  executed project — `ProjectServer.in_flight/1` reports names alone. Callers
  treat a missing entry as "running, for an unknown length of time" rather than
  as not running; `in_flight/1` remains the answer to *whether*.

  The light harness is the case this exists for, and there the ledger is the
  record by definition.
  """
  @spec in_flight_since(Scope.t()) :: %{String.t() => DateTime.t()}
  def in_flight_since(%Scope{} = scope) do
    case remote_executor(scope) do
      {:ok, _pid} -> RunsRepository.running_since(scope)
      :none -> %{}
    end
  end

  @doc """
  Whether anything is running, nothing is, or nobody is watching.

  `in_flight/1` answered `[]` for the last two alike, which renders absent
  information as good news. A project with no entry in `Analysis.Registry` —
  no server started for it, or a build without the Analysis subtree — is
  *untracked*: nothing would know if a run were in flight.

  That cost a diagnosis in `998f4d93`. A test waited on `runs_in_flight?/1` to
  settle the pipeline before comparing two stop decisions; the project was
  untracked, so the wait returned instantly, settled nothing, and the flake
  stayed at the same rate while looking addressed.

  It decides real behaviour too. `Hooks.Stop.pending_analysis?/1` allows a stop
  as "analysis pending" on this answer, and the stale footer prints "No rerun
  is in flight. Stopping again enqueues one" — a claim about the world that
  untracked cannot support.

  A harness-served project is tracked by definition: the ledger is the record,
  and no `:running` rows genuinely means idle.
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
    # Registry not started — web build or a test app without the Analysis
    # subtree. Nobody is watching, which is not the same as nothing running.
    ArgumentError -> :untracked
  end

  defp sources_or_idle([]), do: :idle
  defp sources_or_idle(sources), do: {:running, sources}

  @doc """
  The light harness holding this project, or `:none`.

  A pid, not a boolean: it is both the answer to "can an analyzer run for this
  project" and the thing a run is dispatched to, and keeping those the same
  fact is what stops a run being enqueued for a harness that has gone.
  """
  @spec remote_executor(Scope.t()) :: {:ok, pid()} | :none
  # Keyed on the working copy, because that is what runs the analyzers: two
  # checkouts of one project each have their own toolchain and their own
  # `_build`, and a result from one says nothing about the other.
  #
  # A scope with no harness has no working copy to dispatch to, so `:none` — the
  # same answer it gave for a project nothing was serving. Callers already treat
  # that as "nothing remote here".
  def remote_executor(%Scope{active_harness_id: nil}), do: :none

  def remote_executor(%Scope{active_harness_id: harness_id}) do
    case Registry.lookup(HarnessRegistry, to_string(harness_id)) do
      [{pid, _}] -> {:ok, pid}
      [] -> :none
    end
  rescue
    # No registry — an application build that does not mount the harness
    # channel. Nothing is serving this project remotely.
    ArgumentError -> :none
  end

  @doc """
  Ask a harness to perform a filesystem operation on its own working copy.

  The transport behind `Environments.Harness`. Reads and writes both: the server
  holds no checkout, so a spec stub has to be written on the machine that does.

  Addressed by harness id, resolved through the same registry
  `remote_executor/1` uses — the entry is the channel process, so "is this
  harness alive" and "where do I send this" are one fact rather than two that
  can disagree.

  Errors are `{:error, {tag, details}}`, never a bare atom. Deliberately not
  `:no_environment`: that means there is no working copy, these mean there is
  one and it could not be reached. Anything that prunes or reports absence has
  to tell them apart.

  The tag says which, because the fixes are different and the reader cannot
  guess:

    * `:harness_not_registered` — nothing is registered under that id. The
      harness has not joined since this server started; restarting it rejoins.
    * `:harness_timeout` — it *is* registered, accepted the request, and did
      not answer. Not a connection problem. Carries `elapsed_ms` and `limit_ms`.
    * `:harness_self_call` — the caller *is* the channel process. A wiring bug
      in this server; the harness is fine.
    * `:harness_registry_down` — the registry itself is not running, which is
      this server's problem rather than any harness's.

  All three used to be `:harness_unreachable`. That reads as "no harness", so a
  timeout sent a reader after a registration problem that was not there, and
  the details — working copy, op, elapsed — existed at the point of failure and
  were dropped on the floor.
  """
  @impl CodeMySpec.Environments.HarnessTransport
  @spec harness_fs_request(String.t(), String.t(), map(), timeout()) ::
          {:ok, term()} | :ok | {:error, term()}
  def harness_fs_request(harness_id, op, payload, timeout) do
    started = System.monotonic_time(:millisecond)

    # Explicit `try`, so the catch clauses can see `started`. A function-level
    # `catch` cannot — the elapsed time is the whole point of the timeout branch.
    try do
      case Registry.lookup(HarnessRegistry, to_string(harness_id)) do
        [{pid, _}] ->
          GenServer.call(pid, {:fs_request, op, payload}, timeout + 5_000)

        [] ->
          # Cost, measured: a harness that had joined 57 seconds earlier — its
          # `JOINED harness_project:…` in web.log, the server alive, `/health`
          # answering `serving 3, degraded false` — still produced a bare
          # `Error: :harness_unreachable` at the agent, which reads as "no
          # harness" and sends the reader after a registration problem that is
          # not there.
          Logger.warning(
            "[Analysis] #{op} for harness #{harness_id}: nothing registered under that id. " <>
              "The harness has not joined the channel since this server started — its own " <>
              "/health will still say connected, because that is about its socket rather " <>
              "than about whether the server can address it. Restarting the harness rejoins."
          )

          {:error, {:harness_not_registered, %{harness_id: harness_id, op: op}}}
      end
    rescue
      ArgumentError ->
        Logger.warning(
          "[Analysis] #{op} for harness #{harness_id}: HarnessRegistry is not running"
        )

        {:error, {:harness_registry_down, %{harness_id: harness_id, op: op}}}
    catch
      # A self-call is not a timeout and must not be labelled one. OTP detects
      # it and exits at once with `{:calling_self, …}` — 0ms, not the limit —
      # and `FsRequestSelfCallTest` has said so in prose the whole time while
      # the atom said otherwise. It is a wiring bug (a reconcile running inline
      # in the channel process reached for a file), so the fix is in our code,
      # not in the harness that is answering perfectly well.
      :exit, {:calling_self, _} = reason ->
        Logger.warning(
          "[Analysis] #{op} for harness #{harness_id} was called from the channel process " <>
            "itself: #{inspect(reason, limit: 3)}. Nothing is wrong with the harness — this " <>
            "is a reconcile reaching for a file from inside the process that would serve it."
        )

        {:error, {:harness_self_call, %{harness_id: harness_id, op: op}}}

      :exit, reason ->
        elapsed = System.monotonic_time(:millisecond) - started
        limit = timeout + 5_000

        Logger.warning(
          "[Analysis] #{op} for harness #{harness_id} did not complete after " <>
            "#{elapsed}ms (limit #{limit}ms): #{inspect(reason, limit: 5)}. The harness is " <>
            "registered, so this is not a connection problem — it accepted the request and " <>
            "did not answer."
        )

        {:error,
         {:harness_timeout,
          %{harness_id: harness_id, op: op, elapsed_ms: elapsed, limit_ms: limit}}}
    end
  end

  @doc """
  Register the calling process as the executor for `project_id`.

  Called from the harness channel at join. The registration dies with the
  channel, which is what makes `remote_executor/1` a liveness answer rather than
  a stored one.

  `instance` names the OS process holding the harness's socket. A harness that
  reconnects presents the same `harness_id` as the registration it is colliding
  with — that id *is* the working copy, read from a file inside it — so the id
  alone cannot say whether this is a rival or the same process returning. The
  instance can, and a process is allowed to take its own registration back.

  It has to be, because the entry only dies with the channel, and a channel is
  only killed by its socket closing. A harness whose client-side channel went
  while the socket stayed open leaves an entry nothing will ever release, and
  the harness then queues behind its own ghost at the capped backoff forever —
  hooks refusing with `:not_connected` against a server answering 200. That was
  not a slow recovery, it was a permanent one, and only killing the harness
  process cleared it.

  A *different* instance is still refused: that is two harnesses on one
  `_build`, where two `mix test` runs corrupt it into reporting failures that
  are not in the code. Registered entries are always live — Registry drops them
  when the channel dies — so a live entry from another instance means a real
  rival, not a leftover.
  """
  @spec register_executor(String.t(), String.t() | nil) ::
          :ok | {:error, {:already_registered, pid()}}
  def register_executor(harness_id, instance \\ nil) do
    key = to_string(harness_id)

    case Registry.register(HarnessRegistry, key, instance) do
      {:ok, _} -> :ok
      {:error, {:already_registered, pid}} -> take_over(key, pid, instance)
    end
  end

  @doc """
  Who is holding this working copy's executor slot, if anyone.

  Exists for the refusal message. "A second agent is refused" is only half of
  criterion 744; the half that matters to whoever hit it is *which* agent holds
  it, because the operator is looking at two processes and has to know which one
  to stop. The registry is the only place that knows, and the entry is live by
  construction — Registry drops it when the channel dies — so a hit here names a
  process that is really there.

  `instance` is what the harness called itself at join, typically its OS pid. It
  can be nil for a harness that predates the field, in which case the pid is all
  there is to say and is still better than "another harness".
  """
  @spec executor_holder(String.t()) :: {:ok, pid(), String.t() | nil} | :error
  def executor_holder(harness_id) do
    case Registry.lookup(HarnessRegistry, to_string(harness_id)) do
      [{pid, instance} | _] -> {:ok, pid, instance}
      [] -> :error
    end
  end

  # Only from the same instance, and only when we know both — an unknown
  # instance on either side is not evidence of sameness, and guessing wrong
  # here is the `_build` corruption the lock exists to prevent.
  defp take_over(_key, pid, nil), do: {:error, {:already_registered, pid}}

  defp take_over(key, pid, instance) do
    case Registry.lookup(HarnessRegistry, key) do
      [{^pid, ^instance}] -> evict(key, pid, instance)
      # It went between the register and the lookup. The slot is free now.
      [] -> register_executor(key, instance)
      _ -> {:error, {:already_registered, pid}}
    end
  end

  # Kill it and wait for the entry to actually clear. Registry unregisters on
  # the process's :DOWN, so registering before that lands would race and lose.
  defp evict(key, pid, instance) do
    Logger.info(
      "[Analysis] harness #{key} reconnected from #{instance}; taking back the " <>
        "registration held by its previous channel #{inspect(pid)}"
    )

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      5_000 -> Process.demonitor(ref, [:flush])
    end

    case Registry.register(HarnessRegistry, key, instance) do
      {:ok, _} -> :ok
      {:error, {:already_registered, other}} -> {:error, {:already_registered, other}}
    end
  end

  @doc """
  Close out every `:running` run for the project as failed.

  Called when a harness's channel goes, and again when a new one joins. Both are
  moments at which an open run provably cannot be finished: the queue that was
  going to answer it is gone. Left alone, those rows make `in_flight/1` report
  analysis pending on every subsequent stop — which allows the stop with a note
  that results apply next time, forever.
  """
  @spec fail_in_flight(Scope.t(), term()) :: {:ok, non_neg_integer()}
  def fail_in_flight(%Scope{} = scope, reason), do: fail_in_flight(scope, reason, [])

  @doc """
  As `fail_in_flight/2`, sparing the runs the harness says it is still working
  on.

  `claimed` comes from the harness's join payload. It is a claim, not a fact the
  server can check — but the harness is the only thing that knows, since the
  analyzers are OS processes on its machine, and a wrong claim costs one run
  staying `:running` until the next reconnect rather than a wrong result being
  recorded.
  """
  @spec fail_in_flight(Scope.t(), term(), [integer()]) :: {:ok, non_neg_integer()}
  def fail_in_flight(%Scope{} = scope, reason, claimed) do
    {:ok, count} = RunsRepository.fail_running(scope, reason, claimed)

    if count > 0 do
      Logger.warning(
        "[Analysis] closed #{count} stranded run(s): #{inspect(reason)}" <>
          claimed_suffix(claimed)
      )
    end

    {:ok, count}
  end

  defp claimed_suffix([]), do: ""

  defp claimed_suffix(claimed),
    do: " (spared #{length(claimed)} the harness still holds: #{inspect(claimed)})"

  @doc """
  Per-source gauge state for the UI and the freshness check.

  Returns `%{source => %{state, run}}` where state is `:running`, `:fresh`
  (completed at the current fingerprint), `:stale` (inputs changed since),
  or `:failed` (last run crashed/was skipped). Sources with no run are
  `:stale`.
  """
  @spec status(Scope.t()) :: %{String.t() => %{state: atom(), run: Run.t() | nil}}
  def status(%Scope{} = scope) do
    fingerprints = Fingerprint.current(scope)
    latest = RunsRepository.latest_full_runs(scope)
    running = in_flight(scope)

    Map.new(Run.sources(), fn source ->
      state =
        cond do
          source in running -> :running
          not stale?(source, fingerprints, latest) -> :fresh
          match?(%{status: :failed}, latest[source]) -> :failed
          true -> :stale
        end

      {source, %{state: state, run: latest[source]}}
    end)
  end

  @doc """
  Which of `sources` are fresh, in one pass over the file ledger.

  Same answer as `fresh?/2` per source, and the reason to prefer it is cost.
  `Fingerprint.current/2` loads **every file row for the working copy** — 4,544
  on this project — and `fresh?/2` calls it once per source. The stop hook asks
  about every source that has problems, so a turn spent four or five full loads
  of the same table to compute four hashes of it.

  `Fingerprint.current/1` has always computed all four sources from a single
  load. This is that, plus the per-source `latest_completed_run/2` lookups,
  which are indexed and cheap.

  Deliberately not built on `status/1`, which looks like it answers this and
  does not: it reads `latest_full_runs/1` and treats a failed newest run as
  stale, where `fresh?/2` skips failures to find the newest run that actually
  *answered*. That distinction is load-bearing — a duplicate enqueue refused as
  "already queued" must not make a good result stale — so this keeps
  `fresh?/2`'s lookup and only shares the fingerprinting.
  """
  @spec fresh_sources(Scope.t(), [String.t()]) :: MapSet.t(String.t())
  def fresh_sources(%Scope{} = scope, sources) when is_list(sources) do
    fingerprints = Fingerprint.current(scope)

    for source <- sources,
        %Run{input_fingerprint: fp} <- [RunsRepository.latest_completed_run(scope, source)],
        is_binary(fp),
        fp == Map.get(fingerprints, source),
        into: MapSet.new(),
        do: source
  end

  @doc "Is `source`'s last completed run current for today's inputs?"
  @spec fresh?(Scope.t(), String.t()) :: boolean()
  def fresh?(%Scope{} = scope, source) do
    # The latest run that *answered*, not the latest run. A failure — including
    # a duplicate enqueue refused as "already queued" — cannot make a good
    # result stale, and used to, because this took the newest row of any status
    # and then required `:completed`.
    case RunsRepository.latest_completed_run(scope, source) do
      %Run{input_fingerprint: fp} when is_binary(fp) ->
        fp == Fingerprint.current(scope, source)

      _ ->
        false
    end
  end

  @doc """
  The latest run of `source` that produced an answer, or nil.

  The same run `fresh?/2` judges staleness from, exposed because anything
  reporting *about* that staleness — how old it is, how long it took — has to
  describe the same run. Reading the age off `status/1` instead meant the label
  and the number came from different rows whenever the newest run had failed,
  which is the common case: a failure lands sooner than the retry that succeeds.
  """
  @spec latest_answer(Scope.t(), String.t()) :: Run.t() | nil
  def latest_answer(%Scope{} = scope, source),
    do: RunsRepository.latest_completed_run(scope, source)

  # -- Internals --

  defp stale?(source, fingerprints, latest) do
    case latest[source] do
      %Run{status: :completed, input_fingerprint: fp} -> fp != fingerprints[source]
      _ -> true
    end
  end

  # Compile first: it's the cheapest signal and every other source
  # short-circuits on its errors.
  defp order_compile_first(requests) do
    Enum.sort_by(requests, fn {source, _args} -> source != "compiler" end)
  end

  defp build_job(source, args, fingerprint, opts) do
    %{
      source: source,
      args: args,
      kind: kind_for(args),
      fingerprint: fingerprint,
      opts: runner_opt_passthrough(opts) ++ [notify: Keyword.get(opts, :notify, true)]
    }
  end

  # Path-like args mean the caller targeted specific files — the PreToolUse
  # hook rewriting `mix test test/foo_test.exs` into an API run. Those cover
  # only what they name, so they are `:partial` and can never satisfy
  # freshness: `latest_full_run/2` filters on `kind == :full`.
  #
  # The stop hook always requests bare full runs (`@full_args` is empty for
  # every source), so this only ever fires for model-invoked runs.
  #
  # Without the distinction, one `mix test <file>` finished `:completed` at
  # the current fingerprint and `clear_scope/2` replaced the source's Problems
  # wholesale — so running a single test file wiped every other exunit Problem
  # and reported the whole suite fresh and passing.
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

  # The row is opened here and the work happens there. Opening it first is what
  # makes the request recoverable: if the harness never answers, the row stays
  # `:running` until its channel closes and is failed then — where a
  # fire-and-forget push would leave no trace that anything was ever asked for.
  #
  # ## A busy source is sent anyway, and that is the fix for `cc1016a8`
  #
  # This used to drop the request when `job.source` was already running:
  # single-flight, on the reasoning that two `mix test` processes in one
  # `_build` corrupt it. The premise is right and the conclusion was wrong,
  # because it confused "do not run two at once" with "forget that a second was
  # wanted".
  #
  # The harness never needed protecting from this. `AnalysisServer` serialises
  # by construction — one task at a time — and `accept/2` refuses only a source
  # already *queued*, deliberately, since a second pending run would deliver the
  # same answer twice. A source that is merely *running* is accepted and queued
  # behind itself, which is exactly what a sweep triggered by a new commit
  # needs.
  #
  # What dropping cost, measured on `phx-new-generator`: a spex run started at
  # 00:30:24, a commit edited a spex file at 00:30:43, the sweep at 00:31:25
  # planned spex and this dropped it, and the run that finished at 00:33:57
  # answered about the pre-commit tree. Nothing re-queued it. `analysis/wait`
  # then reported "ok" with spex stale and the queue idle — accurate and
  # useless — and `FixBddSpecs`, which gates on `Analysis.fresh?(scope, "spex")`
  # and says to wait and re-evaluate, looped until somebody ran the analyzer by
  # hand.
  #
  # `:joined` was never true either: nothing joined anything, and the caller
  # was told its work was in progress when it had been discarded.
  defp dispatch_remote(scope, job, channel) do
    case RunsRepository.start_run(scope, %{
           source: job.source,
           kind: job.kind,
           args: %{"args" => job.args},
           input_fingerprint: job.fingerprint
         }) do
      {:ok, run} -> send_or_skip(scope, job, channel, run)
      {:error, reason} -> {:error, reason}
    end
  end

  # The same skip the local `Execution.execute/3` applies, decided one step
  # earlier because the machine that would apply it is not this one. Analyzers
  # and test suites against code that does not compile emit garbage, and the
  # skip is what makes a quiet stop re-run the compiler afterwards —
  # `needs_run?/5` looks for this exact reason.
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
    {:ok, run} =
      RunsRepository.start_run(scope, %{
        source: job.source,
        kind: job.kind,
        args: %{"args" => job.args},
        input_fingerprint: job.fingerprint
      })

    case Execution.execute(scope, run, job.opts) do
      {:ok, finished} -> {:ok, finished}
      {:error, reason} -> {:error, reason}
    end
  end

  # The working copy, because that is what owns the build tree the queue exists
  # to protect. Falls back to the project when no harness is bound — the
  # single-checkout case, where the two keys name the same thing.
  #
  # Both callers derive it the same way, so a lookup can never miss a server the
  # other one started.
  @doc false
  # Public only so the property that matters can be asserted directly: two
  # checkouts of one project get different queues, the same checkout gets one.
  def server_key(%Scope{active_harness_id: harness_id}) when not is_nil(harness_id),
    do: {:harness, to_string(harness_id)}

  def server_key(%Scope{active_project_id: project_id}), do: {:project, project_id}

  defp ensure_server(%Scope{active_project_id: project_id} = scope) do
    case DynamicSupervisor.start_child(
           CodeMySpec.Analysis.ServerSupervisor,
           {ProjectServer, {server_key(scope), project_id}}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  # `:timeout` and `:ok` are different answers and used to be the same one.
  #
  # Running out of time returned `:ok`, so "the analyzers finished" and "I gave
  # up waiting" were indistinguishable to every caller. `await_analysis` then
  # reported "Analysis complete" over a queue that was still going, which is the
  # one thing an agent uses that tool to rule out.
  defp poll_until_idle(scope, deadline) do
    cond do
      not runs_in_flight?(scope) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :timeout

      true ->
        Process.sleep(500)
        poll_until_idle(scope, deadline)
    end
  end
end
