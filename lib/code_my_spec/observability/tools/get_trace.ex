defmodule CodeMySpec.Observability.Tools.GetTrace do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Observability
  alias CodeMySpec.Observability.Tools

  @impl true
  def name, do: "get_trace"

  @impl true
  def description do
    """
    Follow one request: the full span tree for a trace id, plus every log
    line emitted during it, joined by trace id.
    """
  end

  @impl true
  def params do
    %{
      trace_id: {:required, {:meta, :string, [description: "The trace id to look up."]}},
      env: {:meta, :string, [description: "'uat' or 'prod'. Default: 'uat'."]}
    }
  end

  @impl true
  def call(%{trace_id: trace_id} = params, context) do
    lookup = fn scope ->
      case Observability.get_trace(scope, trace_id, env: params[:env]) do
        {:error, :not_found} -> {:error, "No trace #{trace_id} found."}
        result -> result
      end
    end

    Tools.run(context, lookup, &format(trace_id, &1))
  end

  defp format(trace_id, %{spans: spans, logs: logs}) do
    "# Trace #{trace_id}\n\n" <>
      "## Spans\n\n" <>
      format_spans(spans) <>
      "\n\n## Logs\n\n" <> format_logs(logs)
  end

  defp format_spans([]), do: "No spans."

  defp format_spans(spans) do
    Enum.map_join(spans, "\n", fn span ->
      "#{span["Timestamp"]} #{span["SpanName"]} (#{span["SpanId"]}, parent #{span["ParentSpanId"]}) " <>
        "#{Tools.duration_ms(span["Duration"])}ms #{span["StatusCode"]}" <>
        if(span["StatusMessage"] in [nil, ""], do: "", else: " — #{span["StatusMessage"]}")
    end)
  end

  defp format_logs([]), do: "No logs."

  defp format_logs(logs) do
    Enum.map_join(logs, "\n", fn log ->
      "#{log["Timestamp"]} [#{log["SeverityText"]}] (span #{log["SpanId"]}) #{log["Body"]}"
    end)
  end
end
