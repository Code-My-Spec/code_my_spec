defmodule CodeMySpec.McpServers.Gsc.Tools.ListSitemapsEnhanced do
  @moduledoc "List sitemaps with detailed info, optionally scoped to a sitemap index."
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Gsc
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :site_url, :string, required: true, doc: "Exact GSC property URL from list_properties"
    field :sitemap_index, :string, doc: "Optional sitemap index URL to list child sitemaps"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- Gsc.list_sitemaps_enhanced(token, params.site_url, params[:sitemap_index]) do
      {:reply, GoogleTools.ok("#{data.count} sitemaps for #{params.site_url}.", data), frame}
    else
      {:error, {:gsc_error, 404, _}} -> {:reply, GoogleTools.text(GoogleTools.site_not_found(params.site_url)), frame}
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end
