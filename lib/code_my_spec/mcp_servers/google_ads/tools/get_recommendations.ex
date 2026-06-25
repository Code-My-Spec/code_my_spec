defmodule CodeMySpec.McpServers.GoogleAds.Tools.GetRecommendations do
  @moduledoc "Active recommendations Google surfaces for the account."
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Ads
  alias CodeMySpec.McpServers.GoogleAds.Tools
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :customer_id, :string, required: true, doc: "Customer ID (e.g. \"123-456-7890\")"
    field :limit, :integer, doc: "Max recommendations to return"
    field :login_customer_id, :string, doc: "Manager (MCC) account ID, when acting on a linked account"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- Ads.get_recommendations(token, params.customer_id, Tools.read_opts(params)) do
      {:reply, GoogleTools.ok("Found #{length(data)} recommendation(s).", data), frame}
    else
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end
