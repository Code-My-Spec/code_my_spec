defmodule CodeMySpec.Observability do
  @moduledoc """
  Reading a project's own deployed logs and traces from its ClickHouse
  telemetry database (story 1116 / "1082", issue 577de9bb's observability
  follow-on).

  Every function here takes the calling `Scope` and an `environment`
  ("uat" by default, rule `08020acd`) and connects as that project's own
  read-only ClickHouse user — never as a shared credential, and never with
  the project name taken from caller-supplied arguments. The connection
  *is* the scope: whatever that user's row policies admit is all a query
  here can ever see, which is the backstop rule `094d4f4b` describes ("an
  agent sees only its own project's logs and traces; nothing it passes can
  widen that"). There is deliberately no `service`/`project` parameter on
  any function below — adding one would invite exactly the widening the
  row policy already forecloses.

  `{:error, :not_configured}` means story 1081 (provisioning) has not set
  this project up for this environment yet — rule `f2136c8c`. Callers
  should say so plainly and point at provisioning, not retry.

  Every query is bounded by both a time window and a row cap (rule
  `fb40bcc5`); a capped result reports `truncated: true` rather than
  silently dropping rows, which is `query_logs/2` and `slow_spans/2`
  fetching `limit + 1` and trimming rather than trusting `LIMIT` alone to
  tell the caller anything.
  """

  use Boundary,
    top_level?: true,
    deps: [CodeMySpec.ProjectSecrets, CodeMySpec.Users.Scope],
    exports: :all

  alias CodeMySpec.Observability.ClickHouseClient
  alias CodeMySpec.Observability.Credentials
  alias CodeMySpec.Users.Scope

  @default_env "uat"
  @default_window_seconds 3600
  @default_limit 100
  @max_limit 1000

  @doc """
  Log lines in `[since, until]`, newest first, capped at `limit` (default
  #{@default_limit}, max #{@max_limit}). `since`/`until` default to the
  last hour. `level`, `text` (substring match against the message body)
  and `trace_id` narrow the search; all are optional.
  """
  @spec query_logs(Scope.t(), keyword()) ::
          {:ok, %{rows: [map()], truncated: boolean()}} | {:error, term()}
  def query_logs(%Scope{} = scope, opts \\ []) do
    env = env(opts)
    {since, until} = window(opts)
    limit = limit(opts)

    with {:ok, conn} <- Credentials.resolve(scope, env) do
      params =
        %{since: ch_time(since), until: ch_time(until), limit: limit + 1}
        |> maybe_put_param(:level, opts[:level])
        |> maybe_put_param(:text_pattern, opts[:text] && "%#{opts[:text]}%")
        |> maybe_put_param(:trace_id, opts[:trace_id])

      sql = """
      SELECT Timestamp, SeverityText, Body, TraceId, SpanId
      FROM otel_logs
      WHERE Timestamp >= {since:DateTime64} AND Timestamp <= {until:DateTime64}
      #{optional_clause(opts[:level], "AND SeverityText = {level:String}")}
      #{optional_clause(opts[:text], "AND Body ILIKE {text_pattern:String}")}
      #{optional_clause(opts[:trace_id], "AND TraceId = {trace_id:String}")}
      ORDER BY Timestamp DESC
      LIMIT {limit:UInt32}
      """

      with {:ok, rows} <- ClickHouseClient.query(conn, sql, params) do
        {:ok, cap(rows, limit)}
      end
    end
  end

  @doc """
  The span tree for `trace_id`, plus every log line emitted during it,
  joined by trace id (rule `4cda53df`). `{:error, :not_found}` when
  nothing in this environment carries that trace id.
  """
  @spec get_trace(Scope.t(), String.t(), keyword()) ::
          {:ok, %{spans: [map()], logs: [map()]}} | {:error, term()}
  def get_trace(%Scope{} = scope, trace_id, opts \\ []) when is_binary(trace_id) do
    env = env(opts)

    with {:ok, conn} <- Credentials.resolve(scope, env),
         {:ok, spans} <- ClickHouseClient.query(conn, trace_spans_sql(), %{trace_id: trace_id}),
         {:ok, logs} <- ClickHouseClient.query(conn, trace_logs_sql(), %{trace_id: trace_id}) do
      if spans == [] and logs == [] do
        {:error, :not_found}
      else
        {:ok, %{spans: spans, logs: logs}}
      end
    end
  end

  defp trace_spans_sql do
    """
    SELECT Timestamp, SpanId, ParentSpanId, SpanName, SpanKind, Duration, StatusCode, StatusMessage
    FROM otel_traces
    WHERE TraceId = {trace_id:String}
    ORDER BY Timestamp ASC
    """
  end

  defp trace_logs_sql do
    """
    SELECT Timestamp, SeverityText, Body, SpanId
    FROM otel_logs
    WHERE TraceId = {trace_id:String}
    ORDER BY Timestamp ASC
    """
  end

  @doc """
  The slowest spans in `[since, now]`, capped at `limit`. `min_duration_ms`
  (default 0 — everything counts as "slow" until a floor is named) and
  `name_like` (substring match against the span name) narrow the search.
  """
  @spec slow_spans(Scope.t(), keyword()) ::
          {:ok, %{rows: [map()], truncated: boolean()}} | {:error, term()}
  def slow_spans(%Scope{} = scope, opts \\ []) do
    env = env(opts)
    {since, _until} = window(opts)
    limit = limit(opts)
    min_duration_ns = (opts[:min_duration_ms] || 0) * 1_000_000

    with {:ok, conn} <- Credentials.resolve(scope, env) do
      params =
        %{since: ch_time(since), min_duration_ns: min_duration_ns, limit: limit + 1}
        |> maybe_put_param(:name_pattern, opts[:name_like] && "%#{opts[:name_like]}%")

      sql = """
      SELECT Timestamp, SpanName, Duration, TraceId, SpanId, StatusCode
      FROM otel_traces
      WHERE Timestamp >= {since:DateTime64} AND Duration >= {min_duration_ns:UInt64}
      #{optional_clause(opts[:name_like], "AND SpanName ILIKE {name_pattern:String}")}
      ORDER BY Duration DESC
      LIMIT {limit:UInt32}
      """

      with {:ok, rows} <- ClickHouseClient.query(conn, sql, params) do
        {:ok, cap(rows, limit)}
      end
    end
  end

  @doc """
  What's going wrong in `[since, now]`, without writing a query: error-level
  log lines grouped by message, and failed spans grouped by name, each with
  a count and the most recent occurrence (rule `34f14a68`).
  """
  @spec error_summary(Scope.t(), keyword()) ::
          {:ok, %{log_errors: [map()], span_errors: [map()]}} | {:error, term()}
  def error_summary(%Scope{} = scope, opts \\ []) do
    env = env(opts)
    {since, _until} = window(opts)
    limit = limit(opts)
    params = %{since: ch_time(since), limit: limit}

    with {:ok, conn} <- Credentials.resolve(scope, env),
         {:ok, log_errors} <- ClickHouseClient.query(conn, log_errors_sql(), params),
         {:ok, span_errors} <- ClickHouseClient.query(conn, span_errors_sql(), params) do
      {:ok, %{log_errors: log_errors, span_errors: span_errors}}
    end
  end

  # Fixed severities, not caller input — a literal in the query text, same
  # as any other constant this module writes, not a bound parameter.
  defp log_errors_sql do
    """
    SELECT Body AS message, count() AS count, max(Timestamp) AS last_seen
    FROM otel_logs
    WHERE Timestamp >= {since:DateTime64} AND SeverityText IN ('ERROR', 'FATAL')
    GROUP BY Body
    ORDER BY count DESC
    LIMIT {limit:UInt32}
    """
  end

  defp span_errors_sql do
    """
    SELECT SpanName AS name, StatusMessage AS message, count() AS count, max(Timestamp) AS last_seen
    FROM otel_traces
    WHERE Timestamp >= {since:DateTime64} AND StatusCode = 'Error'
    GROUP BY SpanName, StatusMessage
    ORDER BY count DESC
    LIMIT {limit:UInt32}
    """
  end

  defp env(opts), do: opts[:env] || @default_env

  defp window(opts) do
    until = opts[:until] || DateTime.utc_now()
    since = opts[:since] || DateTime.add(until, -@default_window_seconds, :second)
    {since, until}
  end

  defp limit(opts), do: opts |> Keyword.get(:limit, @default_limit) |> min(@max_limit)

  defp ch_time(%DateTime{} = dt), do: DateTime.to_string(dt)

  defp optional_clause(nil, _clause), do: ""
  defp optional_clause(_present, clause), do: clause

  defp maybe_put_param(params, _key, nil), do: params
  defp maybe_put_param(params, key, value), do: Map.put(params, key, value)

  # Fetched `limit + 1` so a full page can tell "exactly this many rows
  # exist" apart from "there are more past here" — `LIMIT` alone cannot.
  defp cap(rows, limit) do
    {kept, truncated?} =
      if length(rows) > limit do
        {Enum.take(rows, limit), true}
      else
        {rows, false}
      end

    %{rows: kept, truncated: truncated?}
  end
end
