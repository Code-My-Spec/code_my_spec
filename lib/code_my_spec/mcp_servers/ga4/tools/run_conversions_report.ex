defmodule CodeMySpec.McpServers.Ga4.Tools.RunConversionsReport do
  @moduledoc """
  Run a Google Analytics conversions report. Use this instead of run_report
  for conversions, ad performance, ROAS, or attribution. Requires a
  conversion_spec.
  """
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Ga4
  alias CodeMySpec.McpServers.Ga4.Tools
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :property_id, :string, required: true, doc: "Property ID (number or \"properties/123\")"
    field :date_ranges, {:list, :map}, required: true, doc: "List of {startDate, endDate} objects"
    field :dimensions, {:list, :string}, required: true, doc: "Allowed conversion dimensions"
    field :metrics, {:list, :string}, required: true, doc: "Allowed conversion metrics"
    field :conversion_spec, :map, required: true, doc: "{conversion_actions, attribution_model}"
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
    opts =
      params
      |> Tools.report_opts()
      |> Keyword.put(:conversion_spec, params.conversion_spec)

    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- Ga4.run_conversions_report(token, params.property_id, opts) do
      {:reply, GoogleTools.ok("Conversions report results.", data), frame}
    else
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end
