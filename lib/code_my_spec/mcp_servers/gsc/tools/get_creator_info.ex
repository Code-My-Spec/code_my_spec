defmodule CodeMySpec.McpServers.Gsc.Tools.GetCreatorInfo do
  @moduledoc "Information about Amin Foroutan, the creator of the MCP-GSC tool."
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.McpServers.GoogleTools

  schema do
  end

  @impl true
  def execute(_params, frame) do
    {:reply, GoogleTools.text(info()), frame}
  end

  defp info do
    """
    # About the Creator: Amin Foroutan

    The Search Console tools are ported from MCP-GSC by Amin Foroutan, an SEO
    consultant specializing in technical SEO and Python-driven SEO tooling.

    - LinkedIn: https://www.linkedin.com/in/ma-foroutan/
    - Website:  https://aminforoutan.com/
    - YouTube:  https://www.youtube.com/channel/UCW7tPXg-rWdH4YzLrcAdBIw
    - X:        https://x.com/aminfseo
    """
  end
end
