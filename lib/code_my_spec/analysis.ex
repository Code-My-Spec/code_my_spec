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
  """

  require Logger

  alias CodeMySpec.Analysis.{Execution, Fingerprint, ProjectServer, Run, RunsRepository}
  alias CodeMySpec.Users.Scope

  # `:async` (default) runs jobs through the per-project ProjectServer —
  # supervised background tasks, single-flight, survives HTTP disconnects.
  # `:inline` (test env) executes in the caller process: sandbox-owned DB
  # connections, deterministic ordering, old synchronous stop semantics.
  defp mode, do: Application.get_env(:code_my_spec, :analysis_mode, :async)

  # Canonical full-run args per source. `--stale` delegates test selection to
  # mix's own manifest — semantically a full run.
  @full_args %{
    "compiler" => [],
    "credo" => [],
    "exunit" => ["--stale"],
    "spex" => ["--stale"]
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

    {stale, memoized} =
      requests
      |> Enum.map(&normalize_request/1)
      |> order_compile_first()
      |> Enum.split_with(fn {source, args} ->
        needs_run?(source, args, fingerprints, latest, only_failed)
      end)

    Enum.each(stale, fn {source, args} ->
      job = build_job(source, args, fingerprints[source], opts)
      dispatch(scope, job)
    end)

    stale_sources = Enum.map(stale, &elem(&1, 0))
    memoized_sources = Enum.map(memoized, &elem(&1, 0))

    if stale_sources != [], do: Logger.info("[Analysis] enqueued: #{Enum.join(stale_sources, ", ")}")

    if memoized_sources != [],
      do: Logger.info("[Analysis] skipped (current): #{Enum.join(memoized_sources, ", ")}")

    %{enqueued: stale_sources, memoized: memoized_sources}
  end

  defp normalize_request({source, args}) when is_list(args), do: {source, args}
  defp normalize_request(source) when is_binary(source), do: {source, Map.fetch!(@full_args, source)}

  defp needs_run?(source, args, fingerprints, latest, only_failed) do
    cond do
      only_failed -> match?(%Run{status: :failed}, latest[source])
      kind_for(args) == :partial -> true
      true -> stale?(source, fingerprints, latest)
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
    fingerprint = Fingerprint.current(scope, source)
    job = build_job(source, args, fingerprint, Keyword.put(opts, :notify, false))

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

  @doc "Block until every in-flight run for the project has finished."
  @spec await_all(Scope.t(), keyword()) :: :ok
  def await_all(%Scope{} = scope, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, :timer.minutes(10))
    deadline = System.monotonic_time(:millisecond) + timeout
    poll_until_idle(scope, deadline)
  end

  @doc "Any run currently running or queued for the project?"
  @spec runs_in_flight?(Scope.t()) :: boolean()
  def runs_in_flight?(%Scope{} = scope), do: in_flight(scope) != []

  @doc "Sources currently running or queued."
  @spec in_flight(Scope.t()) :: [String.t()]
  def in_flight(%Scope{active_project_id: project_id}) do
    case Registry.lookup(CodeMySpec.Analysis.Registry, project_id) do
      [{pid, _}] -> ProjectServer.in_flight(pid)
      [] -> []
    end
  rescue
    # Registry not started — web build or a test app without the Analysis
    # subtree. No registry, no in-flight runs.
    ArgumentError -> []
  end

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

  @doc "Is `source`'s last completed run current for today's inputs?"
  @spec fresh?(Scope.t(), String.t()) :: boolean()
  def fresh?(%Scope{} = scope, source) do
    case RunsRepository.latest_full_run(scope, source) do
      %Run{status: :completed, input_fingerprint: fp} when is_binary(fp) ->
        fp == Fingerprint.current(scope, source)

      _ ->
        false
    end
  end

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

  # Path-like args make a run partial: it only refreshes the files it covers
  # and never satisfies freshness.
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
    case mode() do
      :inline ->
        run_inline(scope, job)

      :async ->
        {:ok, server} = ensure_server(scope)
        ProjectServer.ensure_run(server, scope, job)
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

  defp ensure_server(%Scope{active_project_id: project_id}) do
    case DynamicSupervisor.start_child(
           CodeMySpec.Analysis.ServerSupervisor,
           {ProjectServer, project_id}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp poll_until_idle(scope, deadline) do
    cond do
      not runs_in_flight?(scope) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :ok

      true ->
        Process.sleep(500)
        poll_until_idle(scope, deadline)
    end
  end
end
