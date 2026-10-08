defmodule CodeMySpec.Telemetry.Reader do
  @moduledoc false

  alias CodeMySpec.Observability.ClickHouseClient
  alias CodeMySpec.Observability.Credentials

  def query(scope, environment, opts) do
    days = Keyword.get(opts, :since_days, 14)

    if is_integer(days) and days > 0 and days <= 14 do
      since = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)
      query_opts = [env: environment, since: since, limit: 100]

      with {:ok, logs} <- CodeMySpec.Observability.query_logs(scope, query_opts),
           {:ok, traces} <- CodeMySpec.Observability.slow_spans(scope, query_opts) do
        {:ok,
         %{logs: logs.rows, traces: traces.rows, truncated: logs.truncated or traces.truncated}}
      end
    else
      {:error, "since_days must be an integer between 1 and 14"}
    end
  end

  def check(scope, environment) do
    case Credentials.resolve(scope, environment) do
      {:ok, connection} ->
        case ClickHouseClient.query(connection, "SELECT Timestamp FROM otel_logs LIMIT 1", %{}) do
          {:ok, _} ->
            %{reachable: true, reads: :ok, writes: write_permission(connection)}

          {:error, {:clickhouse_error, _, _}} ->
            %{reachable: true, reads: :error, writes: :error}

          {:error, _} ->
            unavailable()
        end

      {:error, _} ->
        unavailable()
    end
  end

  # Check authorization without inserting a synthetic log row.
  defp write_permission(connection) do
    sql = "INSERT INTO otel_logs (Timestamp, Body) SELECT now64(9), '' WHERE 0"

    case ClickHouseClient.query(connection, sql, %{}) do
      {:ok, _} ->
        :ok

      {:error, {:clickhouse_error, _, body}} when is_binary(body) ->
        if Regex.match?(~r/Code: *(164|497)[. ]/, body), do: :refused, else: :error

      {:error, _} ->
        :error
    end
  end

  defp unavailable, do: %{reachable: false, reads: :error, writes: :error}
end
