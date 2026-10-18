defmodule CodeMySpec.Observability.Tools.QueryLogs do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Observability
  alias CodeMySpec.Observability.Tools

  @impl true
  def name, do: "query_logs"

  @impl true
  def description do
    """
    Search this project's own deployed logs.

    Always bounded by a time window (default: the last hour) and a row cap
    (default 100, max 1000) — a capped result says so rather than silently
    dropping lines. There is no `service`/`project` parameter: the connection
    this tool makes is already scoped to the calling project, and nothing
    passed here can widen that.
    """
  end

  @impl true
  def params do
    %{
      env: {:meta, :string, [description: "'uat' or 'prod'. Default: 'uat'."]},
      since: {:meta, :string, [description: "ISO 8601 timestamp. Default: one hour ago."]},
      until: {:meta, :string, [description: "ISO 8601 timestamp. Default: now."]},
      level: {:meta, :string, [description: "Exact severity match, e.g. 'ERROR'."]},
      text: {:meta, :string, [description: "Substring match against the log message."]},
      trace_id: {:meta, :string, [description: "Only logs emitted during this trace."]},
      limit: {:meta, :integer, [description: "Max rows (default 100, max 1000)."]}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, since} <- Tools.parse_time(params[:since]),
         {:ok, until} <- Tools.parse_time(params[:until]) do
      opts =
        Tools.opts(
          env: params[:env],
          since: since,
          until: until,
          level: params[:level],
          text: params[:text],
          trace_id: params[:trace_id],
          limit: params[:limit]
        )

      Tools.run(context, &Observability.query_logs(&1, opts), &format/1)
    end
  end

  defp format(%{rows: [], truncated: false}), do: "No matching log lines."

  defp format(%{rows: rows, truncated: truncated?}) do
    header =
      "**#{length(rows)} log line(s)**" <>
        if(truncated?, do: " (truncated — narrow the window or add filters)", else: "")

    header <> "\n\n" <> Enum.map_join(rows, "\n", &format_row/1)
  end

  defp format_row(row) do
    "#{row["Timestamp"]} [#{row["SeverityText"]}] #{row["Body"]}" <>
      if(row["TraceId"] in [nil, ""], do: "", else: " (trace #{row["TraceId"]})")
  end
end
