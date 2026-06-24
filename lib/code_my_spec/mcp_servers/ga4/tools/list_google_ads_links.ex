defmodule CodeMySpec.McpServers.Ga4.Tools.ListGoogleAdsLinks do
  @moduledoc "List the Google Ads links for a property."
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Ga4
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :property_id, :string,
      required: true,
      doc: "Property ID — a number, or a string like \"properties/123456789\""
  end

  @impl true
  def execute(params, frame) do
    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- Ga4.list_google_ads_links(token, params.property_id) do
      {:reply, GoogleTools.ok("Found #{length(data)} Google Ads links.", data), frame}
    else
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end
