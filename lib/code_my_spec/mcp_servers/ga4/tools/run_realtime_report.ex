defmodule CodeMySpec.McpServers.Ga4.Tools.RunRealtimeReport do
  @moduledoc "Run a Google Analytics Data API realtime report (realtime dimensions/metrics only)."
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Ga4
  alias CodeMySpec.McpServers.Ga4.Tools
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :property_id, :string, required: true, doc: "Property ID (number or \"properties/123\")"
    field :dimensions, {:list, :string}, required: true, doc: "Realtime dimension field names"
    field :metrics, {:list, :string}, required: true, doc: "Realtime metric field names"
    field :dimension_filter, :map, doc: "Data API FilterExpression for dimensions"
    field :metric_filter, :map, doc: "Data API FilterExpression for metrics"
    field :order_bys, {:list, :map}, doc: "List of Data API OrderBy objects"
    field :limit, :integer, doc: "Max rows per response (<= 250000)"
    field :offset, :integer, doc: "Start row (0-based)"
    field :return_property_quota, :boolean, doc: "Include realtime property quota in the response"
  end

  @impl true
  def execute(params, frame) do
    opts = Tools.report_opts(params)

    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- Ga4.run_realtime_report(token, params.property_id, opts) do
      {:reply, GoogleTools.ok("Realtime report results.", data), frame}
    else
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end
