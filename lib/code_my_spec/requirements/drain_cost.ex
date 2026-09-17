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
  `story_issues_resolved` is one `UPDATE` across every story's row plus the
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

  defp unwrap([{_project_id, report}]), do: report
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
  @type meta :: %{required(:kind) => :pass | :event, optional(atom()) => term()}

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
    counter = :counters.new(2, [:write_concurrency])

    :telemetry.attach(handler_id, @query_event, &__MODULE__.count_query/4, {owner, counter})
    started = System.monotonic_time()

    try do
      {result, extra} = fun.()
      emit(Map.merge(meta, extra), counter, System.monotonic_time() - started)
      result
    rescue
      error ->
        emit(Map.put(meta, :raised, true), counter, System.monotonic_time() - started)
        reraise error, __STACKTRACE__
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
  def count_query(_event, _measurements, metadata, {owner, counter}) do
    if self() == owner do
      :counters.add(counter, 1, 1)
      :counters.add(counter, 2, rows_written(metadata))
    end

    :ok
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
      rows_written: :counters.get(counter, 2)
    }

    :telemetry.execute(@event, measurements, meta)
    record(meta, measurements)
    log(measurements, meta)
  end

  # Last drain wins, deliberately. A reader asking what an observation cost
  # means the one it just caused, and keeping a history here would be a second,
  # worse copy of the telemetry the log and LiveDashboard already carry.
  defp record(%{project_id: project_id} = meta, measurements) when is_binary(project_id) do
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      _ ->
        :ets.insert(@table, {project_id, report(meta, measurements)})
        :ok
    end
  end

  defp record(_meta, _measurements), do: :ok

  defp report(meta, measurements) do
    %{
      kind: meta.kind,
      duration_ms: System.convert_time_unit(measurements.duration, :native, :millisecond),
      queries: measurements.queries,
      rows_written: measurements.rows_written,
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
        "#{measurements.queries} queries, #{measurements.rows_written} rows written" <>
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
end
