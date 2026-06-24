defmodule CodeMySpec.McpServers.Ga4.Tools.RunFunnelReport do
  @moduledoc """
  Run a Google Analytics Data API funnel report (Alpha). Each funnel step
  has a name and either an `event` shorthand or a complete
  `filter_expression`.
  """
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Ga4
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :property_id, :string, required: true, doc: "Property ID (number or \"properties/123\")"
    field :funnel_steps, {:list, :map}, required: true, doc: "Steps: each {name, event} or {name, filter_expression}"
    field :date_ranges, {:list, :map}, doc: "List of {startDate, endDate} objects"
    field :funnel_breakdown, :map, doc: "{breakdown_dimension: \"deviceCategory\"}"
    field :funnel_next_action, :map, doc: "{next_action_dimension: \"eventName\", limit: 5}"
    field :segments, {:list, :map}, doc: "List of Data API Segment objects"
    field :return_property_quota, :boolean, doc: "Include property quota in the response"
  end

  @impl true
  def execute(params, frame) do
    opts =
      [
        funnel_steps: params.funnel_steps,
        date_ranges: params[:date_ranges],
        funnel_breakdown: params[:funnel_breakdown],
        funnel_next_action: params[:funnel_next_action],
        segments: params[:segments],
        return_property_quota: params[:return_property_quota] || false
      ]

    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- Ga4.run_funnel_report(token, params.property_id, opts) do
      {:reply, GoogleTools.ok("Funnel report results.", data), frame}
    else
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end
