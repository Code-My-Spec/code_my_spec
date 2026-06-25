defmodule CodeMySpec.McpServers.GoogleAds.Tools.UpdateCampaignBudget do
  @moduledoc "Set a campaign budget's daily amount. Mutating — requires approval."
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Ads
  alias CodeMySpec.McpServers.GoogleAds.Tools
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :customer_id, :string, required: true, doc: "Customer ID (e.g. \"123-456-7890\")"
    field :budget_id, :string, required: true, doc: "Campaign budget ID"
    field :amount_micros, :integer, required: true, doc: "Daily amount in micros (1_000_000 = 1 currency unit)"
    field :login_customer_id, :string, doc: "Manager (MCC) account ID, when acting on a linked account"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <-
           Ads.update_campaign_budget(
             token,
             params.customer_id,
             params.budget_id,
             params.amount_micros,
             Tools.write_opts(params)
           ) do
      {:reply, GoogleTools.ok("Campaign budget updated.", data), frame}
    else
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end
