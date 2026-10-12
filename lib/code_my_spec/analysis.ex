defmodule CodeMySpec.Analysis do
  @moduledoc """
  The analysis run service: what ran, when, over which inputs — and the
  single execution path shared by the stop hook and model-invoked test runs.

  Analyzer sources (`compiler`, `credo`, `exunit`, `spex`) execute as
  supervised background jobs, serialized per project, with results reconciled
  into Problems and recorded in the `analysis_runs` ledger. The latest
  completed `:full` run answers for its source, however old; whether it ran at
  a given commit is `Run.at_commit?/2`, which the promote gate reads
  (28d72f8a).

  Entry points:

  - `ensure_stale_runs/3` — stop hook: enqueue what the stop calls for,
    return immediately.
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
      CodeMySpec.Users.Scope,
      CodeMySpec.Validation.Blocking
    ],
    exports: :all

  # The transport `Environments.Harness` reaches a working copy over. Declared
  # there and wired here, because `Environments` is a leaf that everything
  # depends on and cannot name this module without closing a cycle.
  @behaviour CodeMySpec.Environments.HarnessTransport

  require Logger

  alias CodeMySpec.Analysis.{
    Execution,
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
  Enqueue a background run for every requested source. Compile is enqueued
  first — every other source skips itself while it lands errors.

  Called by explicit analysis only: `start_analysis`, ready_for_qa
  certification and promotion. A stop never calls this (John, 2026-10-04).

  Each request is a source string (canonical full run) or a
  `{source, args}` tuple (e.g. credo scoped to some files). Requests with
  path-like args are `:partial`.

  Returns `%{enqueued: [source], memoized: []}` immediately; jobs run in the
  background and reconcile Problems as they land. `memoized` stays in the shape
  for callers that report it, and is always empty: an explicit request always
  runs.

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
    job = build_job(source, args, opts)

    case remote_executor(scope) do
      {:ok, channel} ->
        dispatch_remote(scope, job, channel)

      :none ->
        start_local(scope, job, mode())
    end
  end

  # `mode/0` decides, as it does for `await_local/2`. This always started a
  # ProjectServer, so under `analysis_mode: :inline` — the test env — a run
  # requested through `start_analysis` became an async server under the
  # application supervisor that outlived the test, then ran its queued job
  # against that test's `InMemoryEnvironment` after it was gone. The logged
  # `:noproc` landed in whichever spex was running at the time; story 1052's
  # criterion 3215 was the one that kept catching it.
  # Admission, not outcome. The run is opened and executed here, and whatever
  # the execution does is recorded on the run — the caller asked whether the run
  # was accepted, which it was. Answering with the execution's error made a suite
  # that failed to boot read as a refused request.
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
    job = build_job(source, args, Keyword.put(opts, :notify, false))

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
        run = RunsRepository.record_tree(run, Map.take(payload, ["completed_commit"]))
        result = apply_remote_result(scope, run, payload)
        announce(scope, run, result)
        result
    end
  end

  def record_remote_result(_scope, _payload), do: {:error, :invalid_result}

  @doc """
  Record the commit a harness's analyzer started on, and whether the tree was
  clean then, and when it began. The row was opened at dispatch; the analyzer may have sat in the
  harness's queue since, so its start is when it actually ran.
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
      {:analysis,
       %{
         source: run.source,
         status: status,
         run_id: run.id,
         started_at: run.started_at,
         working_copy_id: run.working_copy_id
       }}
    )

    # Not to the graph: `Reconciler.reconcile/4` tells it, once, on the success
    # path, and only for spex — the one source a requirement reads (28d72f8a).
    # A failed run changes nothing a requirement reads.
    :ok
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

  # `tied_to` names the run_id that actually owns this result — `nil` for the
  # one the harness dispatched, the primary run's id for every request that
  # got tied onto it instead of starting a second execution
  # (`CmsHarness.Project.AnalysisServer.tie_to_queued/4`, story 839). Both
  # carry the identical Problems, because there was only ever one execution;
  # reconciling both wrote every problem twice (`57333540`). Only the primary
  # reconciles. A tied run still gets its own row closed — whoever is
  # waiting on that specific run_id needs a real, completed answer — just
  # without a second pass over data the primary already wrote.
  # A targeted run that a full request tied onto ran the whole suite (the
  # harness merges a tie's args), so its result is a full one. Read as partial,
  # nothing reconciled it: the primary was output only, every tied run by design
  # (batch 313e82812, 2026-10-05).
  defp as_executed(%Run{kind: :partial} = run, %{"args" => []}), do: %{run | kind: :full}
  defp as_executed(run, _payload), do: run

  defp reconcile_or_finish_tied(scope, run, result, nil),
    do: Reconciler.reconcile(scope, run, result, notify: true)

  defp reconcile_or_finish_tied(scope, run, result, tied_to) when is_integer(tied_to),
    do: Reconciler.finish_tied(scope, run, result)

  # Whether the harness that produced this was running analyzer code older than
  # the tree it decided about — computed there, because only the harness can see
  # its own boot sha and its own checkout.
  #
  # Carried on `stats`, a free-form map, so this needs no migration and travels
  # with the run rather than being recomputed later against a different moment.
  # `d9f0846c`: findings from a stale build are indistinguishable from ordinary
  # stale findings in the stop response, and the difference is whether stopping
  # again can possibly help.
  defp note_analyzer_staleness(result, %{"analyzer_staleness" => note}) when is_binary(note) do
    Map.update(result, :stats, %{"analyzer_staleness" => note}, fn stats ->
      Map.put(stats || %{}, "analyzer_staleness", note)
    end)
  end

  defp note_analyzer_staleness(result, _payload), do: result

  @doc """
  Block until every in-flight run for the project has finished.

  `timeout: :infinity` waits with no deadline of its own — right for a caller
  that is already async and would rather learn the real outcome late than a
  wrong one on time (`Promotion.gate/1`: nothing is blocked on its reply, so a
  deadline here only turns "still running" into "failed"). The harness's own
  30-minute hard kill (`CmsHarness.Project.AnalysisServer`) is what actually
  bounds a stuck run — every dispatched source is answered, one way or another,
  whether or not anything here is still waiting to hear it.
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

  @doc "Working copies with a run in flight, other than `except_copy_id`."
  @spec running_elsewhere(Scope.t(), Ecto.UUID.t() | nil) :: [Ecto.UUID.t()]
  defdelegate running_elsewhere(scope, except_copy_id), to: RunsRepository

  @doc "Whether the scope's working copy has a run still open."
  @spec running_on?(Scope.t()) :: boolean()
  defdelegate running_on?(scope), to: RunsRepository

  @doc "Whether an agent has a run it requested still in flight on a working copy."
  @spec awaiting_runs?(Scope.t(), Ecto.UUID.t() | nil, String.t()) :: boolean()
  defdelegate awaiting_runs?(scope, working_copy_id, agent_id), to: RunsRepository

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
  def remote_executor(%Scope{active_working_copy_id: nil}), do: :none

  def remote_executor(%Scope{active_working_copy_id: working_copy_id}) do
    case Registry.lookup(HarnessRegistry, to_string(working_copy_id)) do
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
    * `:harness_gone` — registered, took the request, and the process serving
      it died before answering. Carries `elapsed_ms` and `down`, the exit
      reason. Distinct from a timeout because the fixes are opposite — wait
      longer versus find out what took the process down — and because for an
      op that restarts the application it is not a failure at all. The restart
      drains the endpoint the reply was coming back on, so
      `{:shutdown, :draining}` a second in is what one that worked looks like;
      `Promotion.restart_acknowledgement_lost?/1` is where that is decided.
    * `:harness_self_call` — the caller *is* the channel process. A wiring bug
      in this server; the harness is fine.
    * `:harness_registry_down` — the registry itself is not running, which is
      this server's problem rather than any harness's.

  All of them used to be `:harness_unreachable`. That reads as "no harness", so
  a timeout sent a reader after a registration problem that was not there, and
  the details — working copy, op, elapsed — existed at the point of failure and
  were dropped on the floor. Splitting `:harness_gone` back out of
  `:harness_timeout` is the same correction one level finer: a tag that answers
  "did it hang or did it die" for a caller who cannot tell from the outside.
  """
  @impl CodeMySpec.Environments.HarnessTransport
  @spec harness_fs_request(String.t(), String.t(), map(), timeout()) ::
          {:ok, term()} | :ok | {:error, term()}
  def harness_fs_request(working_copy_id, op, payload, timeout) do
    started = System.monotonic_time(:millisecond)

    # Explicit `try`, so the catch clauses can see `started`. A function-level
    # `catch` cannot — the elapsed time is the whole point of the timeout branch.
    try do
      case Registry.lookup(HarnessRegistry, to_string(working_copy_id)) do
        [{pid, _}] ->
          GenServer.call(pid, {:fs_request, op, payload}, timeout + call_grace_ms())

        [] ->
          # Cost, measured: a harness that had joined 57 seconds earlier — its
          # `JOINED harness_project:…` in web.log, the server alive, `/health`
          # answering `serving 3, degraded false` — still produced a bare
          # `Error: :harness_unreachable` at the agent, which reads as "no
          # harness" and sends the reader after a registration problem that is
          # not there.
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
      # A self-call is not a timeout and must not be labelled one. OTP detects
      # it and exits at once with `{:calling_self, …}` — 0ms, not the limit —
      # and `FsRequestSelfCallTest` has said so in prose the whole time while
      # the atom said otherwise. It is a wiring bug (a reconcile running inline
      # in the channel process reached for a file), so the fix is in our code,
      # not in the harness that is answering perfectly well.
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

      # A callee that died is not a callee that hung, and the two want opposite
      # things from the reader: wait longer, versus find out what took the
      # process down. `GenServer.call/3` tells them apart for us — it exits
      # `{:timeout, …}` when the limit is genuinely reached, and with the
      # callee's own exit reason when it dies first — and this clause used to
      # be folded into the one above, so every death was published as a
      # timeout.
      #
      # What that cost: a `promotion_restart` that worked. The restart drains
      # the endpoint, which takes down the channel the reply was coming back
      # on, so the call exits `{:shutdown, :draining}` after about a second. It
      # was reported as a timeout "after 3019ms (limit 605000ms)" — a pair of
      # numbers that cannot describe a timeout — under a sentence insisting
      # this is not a connection problem, when the connection going away is
      # precisely what it was. Six of those in one deploy, at error level,
      # while :4000 was up and serving the new revision.
      #
      # `elapsed_ms` without `limit_ms`, deliberately: the limit is what you
      # compare against when something ran out of time, and printing it beside
      # a death is what made the original line read as a timeout that had not
      # happened.
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
  Ask the harness holding this working copy to rescan it and re-send its manifest.

  The server cannot walk a checkout that is on another machine —
  `Environments.Harness.stream_files/3` answers `:not_supported_on_harness`
  deliberately, because bulk reads are the manifest's job and not a round trip
  per file. So the sync a caller wants is performed where the disk is, and
  arrives the same way every other manifest does.

  Ordinarily nothing needs to ask: the harness watches the working copy and
  sends what changes. The gap is that watching stops while it is disconnected —
  it says so, `"File changes are not being recorded"` — and only a reconnect
  triggers a fresh full scan. An agent that has reason to believe the graph is
  stale otherwise has no lever, which is what `sync_project` answering
  `{:cannot_scan, :not_supported_on_harness}` left it with.

  Fire-and-forget, like `run_analysis` and for the same reason: the far side
  does the work, and a full scan of a few thousand files takes seconds. The
  result is the manifest, which lands on the ordinary `observations` path and
  reconciles there. Nothing is returned but whether the request was delivered.
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
  # The requester is not told here. These runs are orphans, not failures, and
  # the next join settles each one (`resume_orphaned/2`): reopened, run again,
  # or — only then — reported as failed. Announcing now also could not work:
  # the agent's transport is the harness that just went away, so the message
  # was refused as `:harness_not_connected` and the agent waited on a run
  # nobody was going to finish (cc578c21).
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

  # A run killed on every attempt is killing its harness, or landing in a
  # restart storm. Either way running it again is not going to help.
  @max_redispatches 3

  @doc """
  Settle the runs this copy's harness took with it when it went, now that one
  has joined again.

  Every code_my_spec promote restarts :4000 and then the harness, which fails
  every copy's in-flight runs (`fail_in_flight/3`, `fail_stranded_runs/0`).
  Those are not answers. metric_flow's spex run 53537 died that way at
  14:00:33 on 2026-09-30, and its coder answered "Your turn is done" nudges
  until somebody queued it again by hand 16 minutes later (cc578c21).

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

  # `start_analysis` writes `agent_id` (nil for a session with no agent row) and
  # answers later, so its answer is still owed. A blocking `await_run/4` — the
  # agent's own `mix test` — answered its caller with an error when the channel
  # went, and that caller asks again itself. Nothing unrequested is re-run.
  # An agent waiting on a run it did not start (`wait_on_running_at_commit/4`)
  # is owed its answer too.
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
  `:none` (no full run yet). Nothing here says whether a run is current — the
  latest completed run answers, and the promote gate is keyed on the commit
  (28d72f8a).
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
  The latest run of `source` that produced an answer, or nil.

  The run that answers for `source`, however old (28d72f8a). Anything
  reporting *about* that answer — how old it is, which commit — has to
  describe the same run. Reading the age off `status/1` instead meant the label
  and the number came from different rows whenever the newest run had failed,
  which is the common case: a failure lands sooner than the retry that succeeds.
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
      # Who asked, carried as a plain value from here rather than read back
      # off `Logger.metadata()` at the point a Run row gets written: that
      # metadata is per-process, and `StartAnalysis` (among others) hands this
      # job to an unlinked `Task` that starts with none of it. A caller that
      # knows who's asking says so in `opts[:requested_by]`; one that doesn't
      # leaves this `nil`, same as an unset `args`/`stats`.
      requested_by: Keyword.get(opts, :requested_by),
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
  # useless — and `FixBddSpecs`, which then gated on spex being fresh
  # and says to wait and re-evaluate, looped until somebody ran the analyzer by
  # hand.
  defp dispatch_remote(scope, job, channel) do
    case joinable_run(scope, job) do
      %Run{} = run -> join_remote(job, channel, run)
      nil -> open_remote(scope, job, channel)
    end
  end

  # A harness holds at most two entries per source — the one executing and the
  # one queued behind it — and ties every further request onto the queued one
  # (`CmsHarness.Project.AnalysisServer.tie_to_queued/4`). Opening a row for
  # each of those anyway is what made one queued run read as six `:running`
  # rows (75acdb84). So once two full rows are open, the newest is the queued
  # entry or tied to it, and a new request joins it instead.
  #
  # Still sent, under the joined id: the harness ignores a run it already
  # holds, and one it lost (a restart) is queued afresh rather than waited on
  # forever.
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

  # The working copy, because that is what owns the build tree the queue exists
  # to protect. Falls back to the project when no harness is bound — the
  # single-checkout case, where the two keys name the same thing.
  #
  # Both callers derive it the same way, so a lookup can never miss a server the
  # other one started.
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

      deadline != :infinity and System.monotonic_time(:millisecond) >= deadline ->
        :timeout

      true ->
        Process.sleep(500)
        poll_until_idle(scope, deadline)
    end
  end

  # Added on top of a caller's requested timeout before concluding the
  # harness is gone rather than merely slow -- "the machine is there and
  # did not finish" needs distinguishing from "no harness" (see the
  # `:exit, {:timeout, _}` clause above). 5s in every real environment;
  # configurable so a test proving the timeout path fires doesn't have to
  # pay the real grace period to do it.
  defp call_grace_ms, do: Application.get_env(:code_my_spec, :call_grace_ms, 5_000)
end
