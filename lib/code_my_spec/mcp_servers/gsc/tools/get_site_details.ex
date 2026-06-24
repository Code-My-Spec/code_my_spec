defmodule CodeMySpec.McpServers.Gsc.Tools.GetSiteDetails do
  @moduledoc "Get verification and ownership details for a Search Console property."
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Gsc
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :site_url, :string, required: true, doc: "Exact GSC property URL from list_properties"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- Gsc.get_site_details(token, params.site_url) do
      {:reply, GoogleTools.ok("Details for #{params.site_url}.", data), frame}
    else
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end
