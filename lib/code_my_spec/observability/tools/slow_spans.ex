defmodule CodeMySpec.Observability.Tools.SlowSpans do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Observability
  alias CodeMySpec.Observability.Tools

  @impl true
  def name, do: "slow_spans"

  @impl true
  def description do
    """
    The slowest spans in this project's own traces, without writing a query.

    Bounded by a time window (default: the last hour) and a row cap (default
    100, max 1000).
    """
  end

  @impl true
  def params do
    %{
      env: {:meta, :string, [description: "'uat' or 'prod'. Default: 'uat'."]},
      since: {:meta, :string, [description: "ISO 8601 timestamp. Default: one hour ago."]},
      min_duration_ms: {:meta, :integer, [description: "Only spans at or above this duration."]},
      name_like: {:meta, :string, [description: "Substring match against the span name."]},
      limit: {:meta, :integer, [description: "Max rows (default 100, max 1000)."]}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, since} <- Tools.parse_time(params[:since]) do
      opts =
        Tools.opts(
          env: params[:env],
          since: since,
          min_duration_ms: params[:min_duration_ms],
          name_like: params[:name_like],
          limit: params[:limit]
        )

      Tools.run(context, &Observability.slow_spans(&1, opts), &format/1)
    end
  end

  defp format(%{rows: [], truncated: false}), do: "No spans matched."

  defp format(%{rows: rows, truncated: truncated?}) do
    header =
      "**#{length(rows)} span(s)**" <>
        if(truncated?,
          do: " (truncated — narrow the window or raise min_duration_ms)",
          else: ""
        )

    header <> "\n\n" <> Enum.map_join(rows, "\n", &format_row/1)
  end

  defp format_row(row) do
    "#{row["Timestamp"]} #{row["SpanName"]} #{Tools.duration_ms(row["Duration"])}ms " <>
      "#{row["StatusCode"]} (trace #{row["TraceId"]})"
  end
end
