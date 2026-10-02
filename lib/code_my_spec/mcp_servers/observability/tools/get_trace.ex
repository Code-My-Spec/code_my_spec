defmodule CodeMySpec.McpServers.Observability.Tools.GetTrace do
  @moduledoc """
  Follow one request: the full span tree for a trace id, plus every log
  line emitted during it, joined by trace id.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Observability

  schema do
    field :trace_id, :string, required: true, description: "The trace id to look up."
    field :env, :string, description: "'uat' or 'prod'. Default: 'uat'."
  end

  @impl true
  def execute(%{trace_id: trace_id} = params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} -> lookup(scope, trace_id, params, frame)
      {:error, reason} -> {:reply, error_response("#{reason}"), frame}
    end
  end

  defp lookup(scope, trace_id, params, frame) do
    case Observability.get_trace(scope, trace_id, env: params[:env]) do
      {:ok, result} -> {:reply, text_response(format(trace_id, result)), frame}
      {:error, :not_configured} -> {:reply, error_response(not_configured_message()), frame}
      {:error, :not_found} -> {:reply, error_response("No trace #{trace_id} found."), frame}
      {:error, reason} -> {:reply, error_response("#{inspect(reason)}"), frame}
    end
  end

  defp not_configured_message do
    "This project has no telemetry set up for this environment yet. " <>
      "Run the telemetry provisioning step first."
  end

  defp format(trace_id, %{spans: spans, logs: logs}) do
    "# Trace #{trace_id}\n\n" <>
      "## Spans\n\n" <> format_spans(spans) <>
      "\n\n## Logs\n\n" <> format_logs(logs)
  end

  defp format_spans([]), do: "No spans."

  defp format_spans(spans) do
    Enum.map_join(spans, "\n", fn span ->
      "#{span["Timestamp"]} #{span["SpanName"]} (#{span["SpanId"]}, parent #{span["ParentSpanId"]}) " <>
        "#{duration_ms(span["Duration"])}ms #{span["StatusCode"]}" <>
        if(span["StatusMessage"] in [nil, ""], do: "", else: " — #{span["StatusMessage"]}")
    end)
  end

  # ClickHouse's JSON output represents UInt64 (what `Duration` is, in
  # nanoseconds) as a string, to avoid precision loss past 2^53 — this
  # always arrives as text, never as a JSON number.
  defp duration_ms(duration_ns), do: duration_ns |> String.to_integer() |> div(1_000_000)

  defp format_logs([]), do: "No logs."

  defp format_logs(logs) do
    Enum.map_join(logs, "\n", fn log ->
      "#{log["Timestamp"]} [#{log["SeverityText"]}] (span #{log["SpanId"]}) #{log["Body"]}"
    end)
  end

  defp text_response(content), do: Response.tool() |> Response.text(content)
  defp error_response(message), do: Response.tool() |> Response.error(message)
end
