defmodule CodeMySpec.Observability.Tools.ErrorSummary do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Observability
  alias CodeMySpec.Observability.Tools

  @impl true
  def name, do: "error_summary"

  @impl true
  def description do
    """
    What's going wrong in this project right now, without writing a query:
    error-level log lines grouped by message, and failed spans grouped by
    name, each with a count and the most recent occurrence.
    """
  end

  @impl true
  def params do
    %{
      env: {:meta, :string, [description: "'uat' or 'prod'. Default: 'uat'."]},
      since: {:meta, :string, [description: "ISO 8601 timestamp. Default: one hour ago."]},
      limit: {:meta, :integer, [description: "Max groups per category (default 100, max 1000)."]}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, since} <- Tools.parse_time(params[:since]) do
      opts = Tools.opts(env: params[:env], since: since, limit: params[:limit])
      Tools.run(context, &Observability.error_summary(&1, opts), &format/1)
    end
  end

  defp format(%{log_errors: [], span_errors: []}), do: "Nothing erroring in this window."

  defp format(%{log_errors: log_errors, span_errors: span_errors}) do
    "## Log errors\n\n" <>
      format_logs(log_errors) <>
      "\n\n## Failed spans\n\n" <> format_spans(span_errors)
  end

  defp format_logs([]), do: "None."

  defp format_logs(rows) do
    Enum.map_join(rows, "\n", fn r ->
      "#{r["count"]}x (last #{r["last_seen"]}) — #{r["message"]}"
    end)
  end

  defp format_spans([]), do: "None."

  defp format_spans(rows) do
    Enum.map_join(rows, "\n", fn r ->
      "#{r["count"]}x (last #{r["last_seen"]}) #{r["name"]} — #{r["message"]}"
    end)
  end
end
