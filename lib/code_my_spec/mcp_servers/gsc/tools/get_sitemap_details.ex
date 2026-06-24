defmodule CodeMySpec.McpServers.Gsc.Tools.GetSitemapDetails do
  @moduledoc "Get detailed information about a specific sitemap."
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Gsc
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :site_url, :string, required: true, doc: "Exact GSC property URL from list_properties"
    field :sitemap_url, :string, required: true, doc: "The full URL of the sitemap to inspect"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- Gsc.get_sitemap_details(token, params.site_url, params.sitemap_url) do
      {:reply, GoogleTools.ok("Details for #{params.sitemap_url}.", data), frame}
    else
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end
