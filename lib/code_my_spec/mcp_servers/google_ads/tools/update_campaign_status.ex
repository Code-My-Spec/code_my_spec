defmodule CodeMySpec.McpServers.GoogleAds.Tools.UpdateCampaignStatus do
  @moduledoc "Set a campaign's status (ENABLED, PAUSED, REMOVED). Mutating — requires approval."
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Ads
  alias CodeMySpec.McpServers.GoogleAds.Tools
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :customer_id, :string, required: true, doc: "Customer ID (e.g. \"123-456-7890\")"
    field :campaign_id, :string, required: true, doc: "Campaign ID"
    field :status, :string, required: true, doc: "ENABLED, PAUSED, or REMOVED"
    field :login_customer_id, :string, doc: "Manager (MCC) account ID, when acting on a linked account"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <-
           Ads.update_campaign_status(
             token,
             params.customer_id,
             params.campaign_id,
             params.status,
             Tools.write_opts(params)
           ) do
      {:reply, GoogleTools.ok("Campaign status set to #{params.status}.", data), frame}
    else
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end
