defmodule CodeMySpec.McpServers.Observability.Tools.ErrorSummary do
  @moduledoc """
  What's going wrong in this project right now, without writing a query:
  error-level log lines grouped by message, and failed spans grouped by
  name, each with a count and the most recent occurrence.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Observability

  schema do
    field :env, :string, description: "'uat' or 'prod'. Default: 'uat'."
    field :since, :string, description: "ISO 8601 timestamp. Default: one hour ago."
    field :limit, :integer, description: "Max groups per category (default 100, max 1000)."
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, opts} <- build_opts(params) do
      case Observability.error_summary(scope, opts) do
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
      {:ok, [env: params[:env], since: since, limit: params[:limit]] |> Enum.reject(fn {_k, v} -> is_nil(v) end)}
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

  defp format(%{log_errors: [], span_errors: []}), do: "Nothing erroring in this window."

  defp format(%{log_errors: log_errors, span_errors: span_errors}) do
    "## Log errors\n\n" <> format_logs(log_errors) <>
      "\n\n## Failed spans\n\n" <> format_spans(span_errors)
  end

  defp format_logs([]), do: "None."

  defp format_logs(rows) do
    Enum.map_join(rows, "\n", fn r -> "#{r["count"]}x (last #{r["last_seen"]}) — #{r["message"]}" end)
  end

  defp format_spans([]), do: "None."

  defp format_spans(rows) do
    Enum.map_join(rows, "\n", fn r ->
      "#{r["count"]}x (last #{r["last_seen"]}) #{r["name"]} — #{r["message"]}"
    end)
  end

  defp text_response(content), do: Response.tool() |> Response.text(content)
  defp error_response(message), do: Response.tool() |> Response.error(message)
end
