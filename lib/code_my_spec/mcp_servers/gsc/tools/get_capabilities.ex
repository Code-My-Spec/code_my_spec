defmodule CodeMySpec.McpServers.Gsc.Tools.GetCapabilities do
  @moduledoc """
  Get a full list of all available Search Console tools and how to get
  started. Call this first when asked what this server can do.
  """
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.McpServers.GoogleTools

  schema do
  end

  @impl true
  def execute(_params, frame) do
    {:reply, GoogleTools.text(capabilities()), frame}
  end

  defp capabilities do
    """
    Google Search Console MCP Server

    GETTING STARTED:
    1. Connect your Google account (with Search Console scope) to CodeMySpec.
    2. Call list_properties to see your GSC sites and get the exact site_url.
    3. Use any tool below with that site_url.

    AVAILABLE TOOLS:

    Properties:
      - list_properties, get_site_details

    Analytics & Reporting:
      - get_search_analytics, get_performance_overview, compare_search_periods,
        get_search_by_page_query, get_advanced_search_analytics

    URL Inspection & Indexing:
      - inspect_url_enhanced, batch_url_inspection, check_indexing_issues

    Sitemaps:
      - get_sitemaps, list_sitemaps_enhanced, get_sitemap_details,
        submit_sitemap, manage_sitemaps

    Destructive (disabled by default; set GSC_ALLOW_DESTRUCTIVE=true):
      - add_site, delete_site, delete_sitemap
    """
  end
end
