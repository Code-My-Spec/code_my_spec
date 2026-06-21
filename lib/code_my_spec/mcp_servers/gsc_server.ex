defmodule CodeMySpec.McpServers.GscServer do
  @moduledoc """
  MCP server exposing Google Search Console tools, ported from
  https://github.com/AminForou/mcp-gsc.

  Scope and Google OAuth token are resolved per call from the working dir
  (see `CodeMySpec.McpServers.GoogleTools`). Destructive tools (add_site,
  delete_site, delete_sitemap) are gated behind `GSC_ALLOW_DESTRUCTIVE`.

  ## Restart required after tool changes

  Adding or removing a `component(...)` below requires a full `cms server`
  restart to take effect — the running BEAM binds its tool registry at boot.
  """

  use Anubis.Server,
    name: "codemyspec-gsc",
    version: "1.0.0",
    capabilities: [:tools]

  alias CodeMySpec.McpServers.Gsc.Tools

  component(Tools.GetCapabilities)
  component(Tools.ListProperties)
  component(Tools.GetSiteDetails)
  component(Tools.AddSite)
  component(Tools.DeleteSite)

  component(Tools.GetSearchAnalytics)
  component(Tools.GetPerformanceOverview)
  component(Tools.GetAdvancedSearchAnalytics)
  component(Tools.CompareSearchPeriods)
  component(Tools.GetSearchByPageQuery)

  component(Tools.InspectUrlEnhanced)
  component(Tools.BatchUrlInspection)
  component(Tools.CheckIndexingIssues)

  component(Tools.GetSitemaps)
  component(Tools.ListSitemapsEnhanced)
  component(Tools.GetSitemapDetails)
  component(Tools.SubmitSitemap)
  component(Tools.DeleteSitemap)
  component(Tools.ManageSitemaps)

  component(Tools.GetCreatorInfo)
  component(Tools.Reauthenticate)
end
