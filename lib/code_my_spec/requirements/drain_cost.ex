defmodule CodeMySpec.Requirements.DrainCost do
  @moduledoc """
  What one drain cost, measured from the database's own telemetry.

  Counts queries and rows written by attaching to `[:code_my_spec, :repo,
  :query]` for the length of the drain, filtered to the draining process, so a
  file sync's own writes (in the syncing process) are not charged to the graph
  work it provoked. Also counts edge rebuilds, project preloads and projection
  write transactions, which the query count cannot separate.

  Not a table: nothing decides anything from these numbers. A reader gets one
  `[DrainCost]` log line per drain, the telemetry event, and `last/1,2`.
  See knowledge/requirements_graph/checkers, "Drain cost".
  """

  use GenServer

  require Logger

  @event [:code_my_spec, :requirements, :drain]
  @query_event [:code_my_spec, :repo, :query]

  # Edge redraws, on their own channel: a redraw that reproduces the stored set
  # writes no rows and is in-memory work no query count can see.
  @edges_event [:code_my_spec, :requirements, :edges_rebuilt]

  # Reads of the project's vantage-invariant half. One per drain is the target,
  # whatever the checkout count.
  @project_preload_event [:code_my_spec, :requirements, :project_preload]

  # Write transactions opened. One per drain is the target; a count per entity
  # means a per-entity write loop, which query counts alone cannot name.
  @projection_write_event [:code_my_spec, :requirements, :projection_write]
  @table :requirements_drain_cost

  @doc """
  Owns the table the last drain per project is kept in, and nothing else.

  The same shape `Faults` uses: a named public table, so a reader can ask what
  the last drain cost without calling into the process that ran it.
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, name: opts[:name] || __MODULE__)

  @impl GenServer
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  What the last drain on this project cost, or `nil` if none has run here.

  Assert on queries and rows, never on duration: duration measures the machine,
  the counts measure the work. Duration is carried for humans.
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

  Kept per kind so two kinds can be compared; `last/1` holds whichever finished
  last. `:event` is a drain applying marks; `:reseed` is a projector seeding a
  vantage whole. `:pass` is accepted but no current caller emits it.
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

  # All six characters, so classification is a prefix. A `SELECT`'s `num_rows`
  # is rows read and must not count as written.
  @write_verbs ~w(INSERT UPDATE DELETE)

  @typedoc """
  What the call site already knows about the drain, carried as event metadata.
  `kind` is as in `last/2`.
  """
  @type meta :: %{required(:kind) => :pass | :event | :reseed, optional(atom()) => term()}

  @doc """
  Run `fun`, and say what it cost.

  `fun` returns `{result, extra_meta}` and `measure/2` returns the `result`;
  `extra_meta` is what only the work can say, such as `handled` vs
  `recomputed`.

  A drain that raises still emits, with `raised: true`, and re-raises.
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
  # Public because a telemetry handler must be a captured remote function.
  # Runs in the process that issued the query; the owner check scopes the count
  # to the drain.
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

  # Where wall time went: `query_time` is the database's share, `queue_time`
  # the pool's (nil when the connection was already held), and the remainder
  # this process's own work.
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

  # Last drain wins, deliberately: the log and telemetry are the history. Kept
  # per kind as well as overall, so one kind cannot overwrite another's reading.
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

  # Numbers inline in the message: read by grepping, not by a parser.
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
  Emitted by `IncrementalGraph` when it redraws a vantage's edges, counted into
  the drain it happened inside. An event rather than a return value, because
  the redraw happens several calls below `measure/2`.
  """
  @spec edges_rebuilt() :: [atom()]
  def edges_rebuilt, do: @edges_event

  @doc """
  Said by `Preloader` when it reads the project's vantage-invariant half,
  counted into the drain it happened inside.

  One per drain is the target, whatever the checkout count.
  """
  @spec project_preload() :: [atom()]
  def project_preload, do: @project_preload_event

  @doc "Said by `GraphStore.write/3` when it opens a write transaction, counted into the drain it happened inside."
  @spec projection_write() :: [atom()]
  def projection_write, do: @projection_write_event
end
