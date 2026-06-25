defmodule CodeMySpec.McpServers.GoogleAds.Tools.GetCampaignPerformance do
  @moduledoc "Campaign-level performance for the date range (default LAST_30_DAYS)."
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Ads
  alias CodeMySpec.McpServers.GoogleAds.Tools
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :customer_id, :string, required: true, doc: "Customer ID (e.g. \"123-456-7890\")"
    field :date_range, :string, doc: "GAQL date range, e.g. LAST_30_DAYS, LAST_7_DAYS"
    field :limit, :integer, doc: "Max rows to return"
    field :login_customer_id, :string, doc: "Manager (MCC) account ID, when acting on a linked account"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- Ads.get_campaign_performance(token, params.customer_id, Tools.read_opts(params)) do
      {:reply, GoogleTools.ok("Found #{length(data)} campaign row(s).", data), frame}
    else
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end
