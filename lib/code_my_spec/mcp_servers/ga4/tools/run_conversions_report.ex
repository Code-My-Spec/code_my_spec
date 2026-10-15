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
    field :property_id, :string, required: true, description: "Property ID (number or \"properties/123\")"
    field :date_ranges, {:list, :map}, required: true, description: "List of {startDate, endDate} objects"
    field :dimensions, {:list, :string}, required: true, description: "Allowed conversion dimensions"
    field :metrics, {:list, :string}, required: true, description: "Allowed conversion metrics"
    field :conversion_spec, :map, required: true, description: "{conversion_actions, attribution_model}"
    field :dimension_filter, :map, description: "Data API FilterExpression for dimensions"
    field :metric_filter, :map, description: "Data API FilterExpression for metrics"
    field :order_bys, {:list, :map}, description: "List of Data API OrderBy objects"
    field :limit, :integer, description: "Max rows per response (<= 250000)"
    field :offset, :integer, description: "Start row (0-based)"
    field :currency_code, :string, description: "ISO 4217 currency code"
    field :return_property_quota, :boolean, description: "Include property quota in the response"
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
