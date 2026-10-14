defmodule CodeMySpec.Requirements.DrainCost do
  @moduledoc """
  What one drain cost, measured from the database's own telemetry.

  ## Why this is not a table

  Nothing in the application decides anything from these numbers. The graph does
  not serve differently, the watcher does not back off, no agent reads them.
  They are a measurement of the implementation rather than a fact about the
  project — so they belong in telemetry and the log, not in a schema, and
  certainly not behind a write on the drain path.

  ## Why it is measured at all

  The rule story 1020 states is "an observation costs work in proportion to what
  it changed, not to the size of the project", and until now the only reading
  available for it was `checked_at` — whether a requirement's row was rewritten.
  That was a fair proxy for the batched pass, where a rewritten row means work
  happened. It is not one for a projection that applies events: settling
  `story_issues_triaged` is one `UPDATE` across every story's row plus the
  exceptions, which is two writes for a population of any size and stamps every
  row. So the cheaper system reads as the more expensive one, and a criterion
  written on the proxy goes red on an improvement.

  Queries and rows written do not have that problem. They say the same thing
  about either implementation, which is what lets the criteria survive the swap.

  ## Counted from Ecto, not from our own bookkeeping

  The handler attaches to `[:code_my_spec, :repo, :query]` for the length of the
  drain and counts what the database was actually asked to do. Anything we
  tallied ourselves would be a second account of the same work, and the one that
  drifts is always the copy.

  Filtered to the calling process, which is what keeps a drain's number about
  the drain. `GraphWatcher` and `ShadowProjector` are both GenServers woken by
  PubSub, so a file sync's whole-tree `upsert_files/2` runs in the syncing
  process and never lands here — this measures the graph work a sync provoked,
  not the sync.

  ## What a reader gets

    * `web.log` / `server.log` — one line per drain, beside the `[GraphWatcher]`
      lines already there. That is the history.
    * LiveDashboard — `CodeMySpecWeb.Telemetry` summarises the event. That is
      the trend.
    * A spex — attaches its own handler across one observation and reads exactly
      what that observation cost, rather than going looking afterwards for which
      record was the last drain.
  """

  use GenServer

  require Logger

  @event [:code_my_spec, :requirements, :drain]
  @query_event [:code_my_spec, :repo, :query]

  # Whether the pass rebuilt the graph's edges, counted the same way the queries
  # are: an event the work emits, tallied for the length of the drain and
  # filtered to the drain's own process.
  #
  # It needs its own channel because neither number already here can see it. An
  # edge rebuild that produces the set already stored deletes nothing and
  # inserts nothing — `delete_edges_outside/2` keeps every pair it was handed
  # and `insert_every/3` is `on_conflict: :nothing` — so `rows_written` reads
  # zero, and it resolves its ids from the same map the node write returned, so
  # `queries` does not move either. The work is a transitive reduction over the
  # whole graph, in memory, and it is invisible to a reading taken at the
  # database.
  #
  # Measured on this project the day it was added: 6640 edges at 1341ms against
  # 2220ms of node computation, and on four narrower vantages the edge rebuild
  # cost *more* than every verdict in the project — 378ms of edges against 187ms
  # of nodes at 1532 nodes. A cost that large cannot be the one thing a pass
  # does not report.
  @edges_event [:code_my_spec, :requirements, :edges_rebuilt]

  # How many times the drain read the project's vantage-invariant half — the
  # components with their dependencies and children, the rules, the questions,
  # the issue stamps. Counted for the same reason the edge rebuild is: it is
  # large, it is paid before any narrowing starts, and no reading taken at the
  # database can separate it from the per-checkout half beside it.
  #
  # A drain settling three checkouts should read it once. Measured on dev
  # 2026-09-21 before it did: 32 queries at one vantage, 64 at two, 133-163 at
  # three — linear in checkouts on a project that had not changed between them.
  @project_preload_event [:code_my_spec, :requirements, :project_preload]

  # How many times the event path opened a write transaction. One per drain is
  # the target; the seed was doing one per entity — ~1,300 per vantage, nine
  # vantages, 17.9s and 26,395 queries with `observations: 0`. Queries alone
  # could not name that: a transaction is a handful of queries however many
  # rows it carries, so the count of transactions is the count of "per entity".
  @projection_write_event [:code_my_spec, :requirements, :projection_write]
  @table :requirements_drain_cost

  @doc """
  Owns the table the last drain per project is kept in, and nothing else.

  The same shape `Faults` uses: a process whose only job is to hold a named
  public table, so a reader can ask what the last drain cost without a
  `GenServer.call` into whichever process happened to run it — the pass and the
  event path are different processes, and a reader should not have to know
  which one answered.
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, name: opts[:name] || __MODULE__)

  @impl GenServer
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  What the last drain on this project cost, or `nil` if none has run here.

  Published so the cost rule is checkable by a reader rather than only by a
  query, for the same reason `inputs_fingerprint` is on every node: "an
  observation costs work in proportion to what it changed" is a claim about
  numbers, and a claim whose evidence lives only in a log line is one nothing
  can assert against.

  Queries and rows rather than milliseconds. Watched on a loaded box, the same
  seventeen-query drain ran at 4ms and 18ms per query inside one minute, so
  duration measures the machine while the counts measure the work. Duration is
  carried anyway, because a human reading it wants it; nothing should assert on
  it.
  """
  @spec last(Ecto.UUID.t() | nil) :: map() | nil
  def last(project_id) when is_binary(project_id) do
    case :ets.whereis(@table) do
      :undefined -> nil
      _ -> project_id |> then(&:ets.lookup(@table, &1)) |> unwrap()
    end
  end

  def last(_no_project), do: nil

  @doc """
  What this project's last drain *of one kind* cost, or `nil` if none has run.

  `last/1` cannot answer the question this feature is actually judged on.
  Applying an observation is only worth the machinery if it is cheaper than
  recomputing from it, and both kinds of drain run on the same settle — so a
  single slot holds whichever finished last and the comparison is lost. The
  pass is usually the survivor, which made the event path's own numbers read as
  absent from every surface that asked.

  `:pass` is a whole recompute; `:event` is a projection maintained from
  handlers; `:reseed` is the projector rebuilding a vantage whole, which is
  what "recomputing" costs once the pass is gone.
  """
  @spec last(Ecto.UUID.t() | nil, :pass | :event | :reseed) :: map() | nil
  def last(project_id, kind) when is_binary(project_id) and kind in [:pass, :event, :reseed] do
    case :ets.whereis(@table) do
      :undefined -> nil
      _ -> @table |> :ets.lookup({project_id, kind}) |> unwrap()
    end
  end

  def last(_no_project, _kind), do: nil

  defp unwrap([{_key, report}]), do: report
  defp unwrap([]), do: nil

  # "INSERT", "UPDATE", "DELETE" are all six characters, which is the whole
  # reason the classification is a prefix rather than a parse. A `SELECT` that
  # reports `num_rows` reports rows *read*, and counting those here would make a
  # large read look like a large write.
  @write_verbs ~w(INSERT UPDATE DELETE)

  @typedoc """
  What the call site already knows about the drain, carried as event metadata.

  `kind` is `:pass` for a whole recompute and `:event` for a projection
  maintained from handlers — the distinction the swap turns on, and the one that
  makes two numbers comparable or not.
  """
  @type meta :: %{required(:kind) => :pass | :event | :reseed, optional(atom()) => term()}

  @doc """
  Run `fun`, and say what it cost.

  `fun` returns `{result, extra_meta}` and `measure/2` returns the `result`. The
  second element is for what only the work itself can say — how many marks a
  drain handled versus fell back on, which is not knowable until the handlers
  have run and which must not be computed a second time to find out.

  A drain that raises still emits, with `raised: true`. It consumed the queries
  it consumed, and a cost reading that goes quiet exactly when something goes
  wrong is the one shape that would make this untrustworthy.
  """
  @spec measure(meta(), (-> {result, map()})) :: result when result: term()
  def measure(meta, fun) when is_map(meta) and is_function(fun, 0) do
    owner = self()
    handler_id = {__MODULE__, owner, System.unique_integer([:positive])}
    counter = :counters.new(7, [:write_concurrency])

    :telemetry.attach_many(
      handler_id,
      [@query_event, @edges_event, @project_preload_event, @projection_write_event],
      &__MODULE__.count_query/4,
      {owner, counter}
    )

    started = System.monotonic_time()

    try do
      {result, extra} = fun.()
      emit(Map.merge(meta, extra), counter, System.monotonic_time() - started)
      result
    catch
      kind, reason ->
        emit(Map.put(meta, :raised, true), counter, System.monotonic_time() - started)
        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      :telemetry.detach(handler_id)
    end
  end

  @doc false
  # Public because a telemetry handler must be a captured remote function — an
  # anonymous one is attached and then warned about on every event.
  #
  # Runs in whichever process issued the query, so comparing against the owner
  # is what scopes the count. Without it a drain would be charged for every
  # query the node happened to run while it was in flight.
  def count_query(event, measurements, metadata, {owner, counter}) do
    if self() == owner do
      case event do
        @edges_event -> :counters.add(counter, 3, 1)
        @project_preload_event -> :counters.add(counter, 4, 1)
        @projection_write_event -> :counters.add(counter, 5, 1)
        _query -> both(counter, measurements, metadata)
      end
    end

    :ok
  end

  # Where a drain's wall time went, beside how many queries it issued. Nineteen
  # queries in 550ms on a loaded box is 29ms a query, and the count cannot say
  # whether that is the statements or the wait for a connection: `query_time`
  # is the database's share, `queue_time` the pool's — nil when the connection
  # was already held — and the remainder is this process's own work.
  defp both(counter, measurements, metadata) do
    :counters.add(counter, 1, 1)
    :counters.add(counter, 2, rows_written(metadata))
    :counters.add(counter, 6, Map.get(measurements, :query_time) || 0)
    :counters.add(counter, 7, Map.get(measurements, :queue_time) || 0)
  end

  defp rows_written(%{query: query, result: {:ok, result}}) when is_binary(query) do
    verb = query |> String.trim_leading() |> String.slice(0, 6) |> String.upcase()

    if verb in @write_verbs, do: Map.get(result, :num_rows) || 0, else: 0
  end

  defp rows_written(_metadata), do: 0

  defp emit(meta, counter, duration) do
    measurements = %{
      duration: duration,
      queries: :counters.get(counter, 1),
      rows_written: :counters.get(counter, 2),
      edges_rebuilt: :counters.get(counter, 3),
      project_preloads: :counters.get(counter, 4),
      projection_writes: :counters.get(counter, 5),
      db: :counters.get(counter, 6),
      queued: :counters.get(counter, 7)
    }

    :telemetry.execute(@event, measurements, meta)
    record(meta, measurements)
    log(measurements, meta)
  end

  # Last drain wins, deliberately. A reader asking what an observation cost
  # means the one it just caused, and keeping a history here would be a second,
  # worse copy of the telemetry the log and LiveDashboard already carry.
  #
  # Kept per kind as well as overall, and that second key is the whole point of
  # the measurement. The claim this feature rests on is that applying an
  # observation is cheaper than recomputing from it — a comparison between a
  # `:pass` drain and an `:event` one. A single slot cannot hold a comparison:
  # both kinds run on the same settle, the later overwrites the earlier, and
  # whichever survives is an accident of ordering. The pass is usually the
  # survivor, which is why the event path's applied-versus-re-derived split read
  # as zero from every surface that asked for it.
  defp record(%{project_id: project_id} = meta, measurements) when is_binary(project_id) do
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      _ ->
        entry = report(meta, measurements)
        :ets.insert(@table, {project_id, entry})
        :ets.insert(@table, {{project_id, entry.kind}, entry})
        :ok
    end
  end

  defp record(_meta, _measurements), do: :ok

  defp report(meta, measurements) do
    %{
      kind: meta.kind,
      raised: Map.get(meta, :raised, false),
      measured_at: DateTime.utc_now(),
      measurement_scope: :projection,
      duration_ms: System.convert_time_unit(measurements.duration, :native, :millisecond),
      queries: measurements.queries,
      rows_written: measurements.rows_written,
      edges_rebuilt: measurements.edges_rebuilt,
      project_preloads: measurements.project_preloads,
      projection_writes: measurements.projection_writes,
      db_ms: System.convert_time_unit(measurements.db, :native, :millisecond),
      queued_ms: System.convert_time_unit(measurements.queued, :native, :millisecond),
      observations: Map.get(meta, :observations),
      handled: Map.get(meta, :handled),
      recomputed: Map.get(meta, :recomputed),
      vantages: Map.get(meta, :vantages)
    }
  end

  # The numbers inline in the message, because this is read by grepping a log
  # for a burst and comparing two lines — not by a parser.
  defp log(measurements, meta) do
    ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.info(
      "[DrainCost] #{meta.kind} drain in #{ms}ms — " <>
        "#{measurements.queries} queries, #{measurements.rows_written} rows written, " <>
        "#{measurements.edges_rebuilt} edge rebuild(s), " <>
        "#{measurements.project_preloads} project preload(s), " <>
        "#{measurements.projection_writes} projection write(s), " <>
        "db #{System.convert_time_unit(measurements.db, :native, :millisecond)}ms, " <>
        "queued #{System.convert_time_unit(measurements.queued, :native, :millisecond)}ms" <>
        detail(meta)
    )
  end

  defp detail(meta) do
    case meta |> Map.drop([:kind, :project_id]) |> Enum.sort() do
      [] -> ""
      pairs -> " (" <> Enum.map_join(pairs, ", ", fn {k, v} -> "#{k}: #{v}" end) <> ")"
    end
  end

  @doc "The event this emits, for anything attaching a handler to it."
  @spec event() :: [atom()]
  def event, do: @event

  @doc """
  Said by the pass when it rebuilds the edge set, counted into the drain it
  happened inside.

  Emitted rather than returned because the drain is measured around
  `recompute_vantage/2` and the decision is taken several calls below it. A
  return value would have to be threaded up through `recompute/1`'s public
  shape to reach the place that could report it.
  """
  @spec edges_rebuilt() :: [atom()]
  def edges_rebuilt, do: @edges_event

  @doc """
  Said by `Preloader` when it reads the project's vantage-invariant half,
  counted into the drain it happened inside.

  One per drain is the target, whatever the checkout count. Emitted rather than
  returned for the same reason the edge rebuild is: the drain is measured around
  `recompute_vantage/2` and this happens a call below it.
  """
  @spec project_preload() :: [atom()]
  def project_preload, do: @project_preload_event

  @doc "Said by `Shadow.write/3` when it opens a write transaction, counted into the drain it happened inside."
  @spec projection_write() :: [atom()]
  def projection_write, do: @projection_write_event
end
