defmodule CodeMySpec.McpServers.Gsc.Tools.SubmitSitemap do
  @moduledoc "Submit (or resubmit) a sitemap to Google."
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Gsc
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :site_url, :string, required: true, doc: "Exact GSC property URL from list_properties"
    field :sitemap_url, :string, required: true, doc: "The full URL of the sitemap to submit"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- Gsc.submit_sitemap(token, params.site_url, params.sitemap_url) do
      {:reply, GoogleTools.ok("Submitted #{params.sitemap_url}.", data), frame}
    else
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end
