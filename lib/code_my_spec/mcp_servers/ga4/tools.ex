# Google Analytics (GA4) MCP tools, ported from
# https://github.com/googleanalytics/google-analytics-mcp — one Anubis
# component module per upstream tool. Thin wrappers over
# `CodeMySpec.Google.Ga4`, rendered via `CodeMySpec.McpServers.GoogleTools`.

defmodule CodeMySpec.McpServers.Ga4.Tools do
  @moduledoc false

  # Builds the shared keyword opts for the report client functions from the
  # tool params, dropping nil values.
  @report_keys [
    :date_ranges,
    :dimensions,
    :metrics,
    :dimension_filter,
    :metric_filter,
    :order_bys,
    :limit,
    :offset,
    :currency_code,
    :return_property_quota
  ]

  @spec report_opts(map()) :: keyword()
  def report_opts(params) do
    @report_keys
    |> Enum.reduce([], fn key, acc ->
      case Map.get(params, key) do
        nil -> acc
        value -> [{key, value} | acc]
      end
    end)
  end
end
