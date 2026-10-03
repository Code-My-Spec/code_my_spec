defmodule CodeMySpec.McpServers.Observability.Tools.QueryLogs do
  @moduledoc """
  Search this project's own deployed logs.

  Always bounded by a time window (default: the last hour) and a row cap
  (default 100, max 1000) — a capped result says so rather than silently
  dropping lines. There is no `service`/`project` parameter: the connection
  this tool makes is already scoped to the calling project, and nothing
  passed here can widen that.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Observability

  schema do
    field :env, :string, description: "'uat' or 'prod'. Default: 'uat'."
    field :since, :string, description: "ISO 8601 timestamp. Default: one hour ago."
    field :until, :string, description: "ISO 8601 timestamp. Default: now."
    field :level, :string, description: "Exact severity match, e.g. 'ERROR'."
    field :text, :string, description: "Substring match against the log message."
    field :trace_id, :string, description: "Only logs emitted during this trace."
    field :limit, :integer, description: "Max rows (default 100, max 1000)."
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, opts} <- build_opts(params) do
      case Observability.query_logs(scope, opts) do
        {:ok, result} -> {:reply, text_response(format(result)), frame}
        {:error, :not_configured} -> {:reply, error_response(not_configured_message()), frame}
        {:error, reason} -> {:reply, error_response("#{inspect(reason)}"), frame}
      end
    else
      {:error, reason} -> {:reply, error_response("#{reason}"), frame}
    end
  end

  defp build_opts(params) do
    with {:ok, since} <- parse_time(params[:since]),
         {:ok, until} <- parse_time(params[:until]) do
      {:ok,
       [env: params[:env], since: since, until: until, level: params[:level], text: params[:text]]
       |> Keyword.merge(trace_id: params[:trace_id], limit: params[:limit])
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

  defp format(%{rows: [], truncated: false}), do: "No matching log lines."

  defp format(%{rows: rows, truncated: truncated?}) do
    header = "**#{length(rows)} log line(s)**" <> if(truncated?, do: " (truncated — narrow the window or add filters)", else: "")
    header <> "\n\n" <> Enum.map_join(rows, "\n", &format_row/1)
  end

  defp format_row(row) do
    "#{row["Timestamp"]} [#{row["SeverityText"]}] #{row["Body"]}" <>
      if(row["TraceId"] in [nil, ""], do: "", else: " (trace #{row["TraceId"]})")
  end

  defp text_response(content), do: Response.tool() |> Response.text(content)
  defp error_response(message), do: Response.tool() |> Response.error(message)
end
