defmodule CodeMySpec.McpServers.Gsc.Tools.DeleteSitemap do
  @moduledoc """
  Delete (unsubmit) a sitemap. Destructive — disabled unless
  GSC_ALLOW_DESTRUCTIVE is enabled.
  """
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Gsc
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :site_url, :string, required: true, doc: "Exact GSC property URL from list_properties"
    field :sitemap_url, :string, required: true, doc: "The full URL of the sitemap to delete"
  end

  @impl true
  def execute(params, frame) do
    if GoogleTools.destructive_allowed?() do
      with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
           {:ok, data} <- Gsc.delete_sitemap(token, params.site_url, params.sitemap_url) do
        {:reply, GoogleTools.ok("Deleted #{params.sitemap_url}.", data), frame}
      else
        {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
      end
    else
      {:reply, GoogleTools.destructive_disabled("delete_sitemap"), frame}
    end
  end
end
