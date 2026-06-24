defmodule CodeMySpec.McpServers.Gsc.Tools.DeleteSite do
  @moduledoc """
  Remove a site from your Search Console properties. Destructive — disabled
  unless GSC_ALLOW_DESTRUCTIVE is enabled.
  """
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Gsc
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :site_url, :string, required: true, doc: "Exact site URL to remove"
  end

  @impl true
  def execute(params, frame) do
    if GoogleTools.destructive_allowed?() do
      with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
           {:ok, data} <- Gsc.delete_site(token, params.site_url) do
        {:reply, GoogleTools.ok("Removed #{params.site_url} from Search Console.", data), frame}
      else
        {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
      end
    else
      {:reply, GoogleTools.destructive_disabled("delete_site"), frame}
    end
  end
end
