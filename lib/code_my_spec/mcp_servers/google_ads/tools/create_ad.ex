defmodule CodeMySpec.McpServers.GoogleAds.Tools.CreateAd do
  @moduledoc "Create a (paused) responsive search ad. Mutating — requires approval."
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Ads
  alias CodeMySpec.McpServers.GoogleAds.Tools
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :customer_id, :string, required: true, doc: "Customer ID (e.g. \"123-456-7890\")"
    field :ad_group_resource_name, :string,
      required: true,
      doc: "Full ad group resource name, e.g. customers/123/adGroups/456"
    field :headlines, {:list, :string}, required: true, doc: "Headline texts (3–15)"
    field :descriptions, {:list, :string}, required: true, doc: "Description texts (2–4)"
    field :login_customer_id, :string, doc: "Manager (MCC) account ID, when acting on a linked account"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <-
           Ads.create_ad(
             token,
             params.customer_id,
             params.ad_group_resource_name,
             params.headlines,
             params.descriptions,
             Tools.write_opts(params)
           ) do
      {:reply, GoogleTools.ok("Created responsive search ad (paused).", data), frame}
    else
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end
