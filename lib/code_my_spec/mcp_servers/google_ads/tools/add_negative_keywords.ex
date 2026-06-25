defmodule CodeMySpec.McpServers.GoogleAds.Tools.AddNegativeKeywords do
  @moduledoc "Add campaign-level negative keywords. Mutating — requires approval."
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Ads
  alias CodeMySpec.McpServers.GoogleAds.Tools
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :customer_id, :string, required: true, doc: "Customer ID (e.g. \"123-456-7890\")"
    field :campaign_resource_name, :string,
      required: true,
      doc: "Full campaign resource name, e.g. customers/123/campaigns/456"
    field :keywords, {:list, :map},
      required: true,
      doc: "List of {text, match_type} where match_type is EXACT, PHRASE, or BROAD"
    field :login_customer_id, :string, doc: "Manager (MCC) account ID, when acting on a linked account"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <-
           Ads.add_negative_keywords(
             token,
             params.customer_id,
             params.campaign_resource_name,
             params.keywords,
             Tools.write_opts(params)
           ) do
      {:reply, GoogleTools.ok("Added #{length(params.keywords)} negative keyword(s).", data), frame}
    else
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end
