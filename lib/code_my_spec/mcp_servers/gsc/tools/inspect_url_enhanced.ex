defmodule CodeMySpec.McpServers.Gsc.Tools.InspectUrlEnhanced do
  @moduledoc "Detailed crawl/index status and rich-results for a specific URL."
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Gsc
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :site_url, :string, required: true, doc: "Exact GSC property URL from list_properties"
    field :page_url, :string, required: true, doc: "The specific URL to inspect"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- Gsc.inspect_url_enhanced(token, params.site_url, params.page_url) do
      {:reply, GoogleTools.ok("Inspection of #{params.page_url}.", data), frame}
    else
      {:error, {:gsc_error, 404, _}} -> {:reply, GoogleTools.text(GoogleTools.site_not_found(params.site_url)), frame}
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end
