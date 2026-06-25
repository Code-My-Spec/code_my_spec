defmodule CodeMySpec.McpServers.GoogleAds.Tools.UpdateBid do
  @moduledoc "Set an ad group criterion's max CPC bid. Mutating — requires approval."
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Ads
  alias CodeMySpec.McpServers.GoogleAds.Tools
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :customer_id, :string, required: true, doc: "Customer ID (e.g. \"123-456-7890\")"
    field :criterion_resource_name, :string,
      required: true,
      doc: "Full resource name, e.g. customers/123/adGroupCriteria/456~789"
    field :cpc_bid_micros, :integer, required: true, doc: "Max CPC bid in micros"
    field :login_customer_id, :string, doc: "Manager (MCC) account ID, when acting on a linked account"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <-
           Ads.update_bid(
             token,
             params.customer_id,
             params.criterion_resource_name,
             params.cpc_bid_micros,
             Tools.write_opts(params)
           ) do
      {:reply, GoogleTools.ok("Bid updated.", data), frame}
    else
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end
