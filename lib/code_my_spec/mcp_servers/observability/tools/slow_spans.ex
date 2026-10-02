defmodule CodeMySpec.McpServers.Observability.Tools.SlowSpans do
  @moduledoc """
  The slowest spans in this project's own traces, without writing a query.

  Bounded by a time window (default: the last hour) and a row cap (default
  100, max 1000).
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Observability

  schema do
    field :env, :string, description: "'uat' or 'prod'. Default: 'uat'."
    field :since, :string, description: "ISO 8601 timestamp. Default: one hour ago."
    field :min_duration_ms, :integer, description: "Only spans at or above this duration."
    field :name_like, :string, description: "Substring match against the span name."
    field :limit, :integer, description: "Max rows (default 100, max 1000)."
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, opts} <- build_opts(params) do
      case Observability.slow_spans(scope, opts) do
        {:ok, result} -> {:reply, text_response(format(result)), frame}
        {:error, :not_configured} -> {:reply, error_response(not_configured_message()), frame}
        {:error, reason} -> {:reply, error_response("#{inspect(reason)}"), frame}
      end
    else
      {:error, reason} -> {:reply, error_response("#{reason}"), frame}
    end
  end

  defp build_opts(params) do
    with {:ok, since} <- parse_time(params[:since]) do
      {:ok,
       [env: params[:env], since: since, min_duration_ms: params[:min_duration_ms]]
       |> Keyword.merge(name_like: params[:name_like], limit: params[:limit])
       |> Enum.reject(fn {_k, v} -> is_nil(v) end)}
    end
  end

  defp parse_time(nil), do: {:ok, nil}

  defp parse_time(iso8601) do
    case DateTime.from_iso8601(iso8601) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _reason} -> {:error, "could not parse timestamp #{inspect(iso8601)} as ISO 8601"}
    end
  end

  defp not_configured_message do
    "This project has no telemetry set up for this environment yet. " <>
      "Run the telemetry provisioning step first."
  end

  defp format(%{rows: [], truncated: false}), do: "No spans matched."

  defp format(%{rows: rows, truncated: truncated?}) do
    header = "**#{length(rows)} span(s)**" <> if(truncated?, do: " (truncated — narrow the window or raise min_duration_ms)", else: "")
    header <> "\n\n" <> Enum.map_join(rows, "\n", &format_row/1)
  end

  defp format_row(row) do
    "#{row["Timestamp"]} #{row["SpanName"]} #{duration_ms(row["Duration"])}ms " <>
      "#{row["StatusCode"]} (trace #{row["TraceId"]})"
  end

  # ClickHouse's JSON output represents UInt64 (what `Duration` is, in
  # nanoseconds) as a string, to avoid precision loss past 2^53 — this
  # always arrives as text, never as a JSON number.
  defp duration_ms(duration_ns), do: duration_ns |> String.to_integer() |> div(1_000_000)

  defp text_response(content), do: Response.tool() |> Response.text(content)
  defp error_response(message), do: Response.tool() |> Response.error(message)
end
