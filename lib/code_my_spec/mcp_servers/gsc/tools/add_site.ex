defmodule CodeMySpec.McpServers.Gsc.Tools.AddSite do
  @moduledoc """
  Add a site to your Search Console properties. Destructive — disabled
  unless GSC_ALLOW_DESTRUCTIVE is enabled.
  """
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Gsc
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :site_url, :string,
      required: true,
      doc: "Exact site URL (e.g. https://example.com/ or sc-domain:example.com)"
  end

  @impl true
  def execute(params, frame) do
    if GoogleTools.destructive_allowed?() do
      with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
           {:ok, data} <- Gsc.add_site(token, params.site_url) do
        {:reply, GoogleTools.ok("Added #{params.site_url} to Search Console.", data), frame}
      else
        {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
      end
    else
      {:reply, GoogleTools.destructive_disabled("add_site"), frame}
    end
  end
end
