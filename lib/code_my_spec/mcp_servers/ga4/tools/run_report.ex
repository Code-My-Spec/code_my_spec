defmodule CodeMySpec.McpServers.Ga4.Tools.RunReport do
  @moduledoc """
  Run a Google Analytics Data API report.

  `date_ranges` is a list of `{startDate, endDate}` objects, `dimensions`
  and `metrics` are lists of API field names. Filters and order_bys accept
  the Data API REST shapes (FilterExpression / OrderBy). Use
  get_custom_dimensions_and_metrics for a property's custom fields.
  """
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Ga4
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :property_id, :string, required: true, doc: "Property ID (number or \"properties/123\")"
    field :date_ranges, {:list, :map}, required: true, doc: "List of {startDate, endDate} objects"
    field :dimensions, {:list, :string}, required: true, doc: "Dimension field names"
    field :metrics, {:list, :string}, required: true, doc: "Metric field names"
    field :dimension_filter, :map, doc: "Data API FilterExpression for dimensions"
    field :metric_filter, :map, doc: "Data API FilterExpression for metrics"
    field :order_bys, {:list, :map}, doc: "List of Data API OrderBy objects"
    field :limit, :integer, doc: "Max rows per response (<= 250000)"
    field :offset, :integer, doc: "Start row (0-based)"
    field :currency_code, :string, doc: "ISO 4217 currency code"
    field :return_property_quota, :boolean, doc: "Include property quota in the response"
  end

  @impl true
  def execute(params, frame) do
    opts = CodeMySpec.McpServers.Ga4.Tools.report_opts(params)

    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- Ga4.run_report(token, params.property_id, opts) do
      {:reply, GoogleTools.ok("Report results.", data), frame}
    else
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end
