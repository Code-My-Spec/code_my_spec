defmodule CodeMySpec.McpServers.Ga4Server do
  @moduledoc """
  MCP server exposing Google Analytics (GA4) Admin + Data API tools, ported
  from https://github.com/googleanalytics/google-analytics-mcp.

  Scope and Google OAuth token are resolved per call from the working dir
  (see `CodeMySpec.McpServers.GoogleTools`). All tools are read-only.

  ## Restart required after tool changes

  Adding or removing a `component(...)` below requires a full `cms server`
  restart to take effect — the running BEAM binds its tool registry at boot.
  """

  use Anubis.Server,
    name: "codemyspec-ga4",
    version: "1.0.0",
    capabilities: [:tools]

  alias CodeMySpec.McpServers.Ga4.Tools

  component(Tools.GetAccountSummaries)
  component(Tools.ListGoogleAdsLinks)
  component(Tools.GetPropertyDetails)
  component(Tools.ListPropertyAnnotations)
  component(Tools.GetCustomDimensionsAndMetrics)

  component(Tools.RunReport)
  component(Tools.RunRealtimeReport)
  component(Tools.RunConversionsReport)
  component(Tools.RunFunnelReport)
end
