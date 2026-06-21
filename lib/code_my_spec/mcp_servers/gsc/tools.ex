# Google Search Console MCP tools, ported from
# https://github.com/AminForou/mcp-gsc — one Anubis component module per
# upstream tool. They are thin wrappers: resolve {scope, token}, call
# `CodeMySpec.Google.Gsc`, and render via `CodeMySpec.McpServers.GoogleTools`.

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

defmodule CodeMySpec.McpServers.Gsc.Tools.ListProperties do
  @moduledoc """
  List all Google Search Console properties the user has access to. Always
  call this first to get the exact site_url needed for other tools.
  """
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Gsc
  alias CodeMySpec.McpServers.GoogleTools

  schema do
  end

  @impl true
  def execute(params, frame) do
    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- Gsc.list_properties(token) do
      {:reply, GoogleTools.ok("Found #{data.count} GSC properties.", data), frame}
    else
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end

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

defmodule CodeMySpec.McpServers.Gsc.Tools.GetSearchAnalytics do
  @moduledoc """
  Top queries and pages with clicks, impressions, CTR, and position for a
  property over the last N days.
  """
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Gsc
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :site_url, :string, required: true, doc: "Exact GSC property URL from list_properties"
    field :days, :integer, doc: "Days to look back (default 28)"
    field :dimensions, :string, doc: "Comma-separated dimensions: query, page, device, country, date (default query)"
    field :row_limit, :integer, doc: "Rows to return (default 20, max 500)"
  end

  @impl true
  def execute(params, frame) do
    opts =
      [
        days: params[:days] || 28,
        dimensions: params[:dimensions] || "query",
        row_limit: params[:row_limit] || 20
      ]

    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- Gsc.get_search_analytics(token, params.site_url, opts) do
      {:reply, GoogleTools.ok("Search analytics for #{params.site_url}.", data), frame}
    else
      {:error, {:gsc_error, 404, _}} -> {:reply, GoogleTools.text(GoogleTools.site_not_found(params.site_url)), frame}
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end

defmodule CodeMySpec.McpServers.Gsc.Tools.GetPerformanceOverview do
  @moduledoc "Summary totals plus a daily trend for a property over the last N days."
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Gsc
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :site_url, :string, required: true, doc: "Exact GSC property URL from list_properties"
    field :days, :integer, doc: "Days to look back (default 28)"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- Gsc.get_performance_overview(token, params.site_url, params[:days] || 28) do
      {:reply, GoogleTools.ok("Performance overview for #{params.site_url}.", data), frame}
    else
      {:error, {:gsc_error, 404, _}} -> {:reply, GoogleTools.text(GoogleTools.site_not_found(params.site_url)), frame}
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end

defmodule CodeMySpec.McpServers.Gsc.Tools.GetAdvancedSearchAnalytics do
  @moduledoc """
  Advanced search analytics with sorting, multi-dimension filtering, search
  type, and pagination.
  """
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Gsc
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :site_url, :string, required: true, doc: "Exact GSC property URL from list_properties"
    field :start_date, :string, doc: "YYYY-MM-DD (default 28 days ago)"
    field :end_date, :string, doc: "YYYY-MM-DD (default today)"
    field :dimensions, :string, doc: "Comma-separated dimensions (default query)"
    field :search_type, :string, doc: "WEB, IMAGE, VIDEO, NEWS, DISCOVER (default WEB)"
    field :row_limit, :integer, doc: "Max rows (max 25000, default 1000)"
    field :start_row, :integer, doc: "Pagination start row (default 0)"
    field :sort_by, :string, doc: "clicks, impressions, ctr, position (default clicks)"
    field :sort_direction, :string, doc: "ascending or descending (default descending)"
    field :filter_dimension, :string, doc: "Single filter dimension: query, page, country, device"
    field :filter_operator, :string, doc: "contains, equals, notContains, notEquals (default contains)"
    field :filter_expression, :string, doc: "Single filter value"
    field :filters, {:list, :map}, doc: "List of {dimension, operator, expression} filter objects (AND logic). Overrides single-filter params."
    field :data_state, :string, doc: "all (default) or final"
  end

  @impl true
  def execute(params, frame) do
    opts =
      params
      |> Map.take([
        :start_date,
        :end_date,
        :dimensions,
        :search_type,
        :row_limit,
        :start_row,
        :sort_by,
        :sort_direction,
        :filter_dimension,
        :filter_operator,
        :filter_expression,
        :filters,
        :data_state
      ])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- Gsc.get_advanced_search_analytics(token, params.site_url, opts) do
      {:reply, GoogleTools.ok("Advanced search analytics for #{params.site_url}.", data), frame}
    else
      {:error, {:gsc_error, 404, _}} -> {:reply, GoogleTools.text(GoogleTools.site_not_found(params.site_url)), frame}
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end

defmodule CodeMySpec.McpServers.Gsc.Tools.CompareSearchPeriods do
  @moduledoc "Compare search analytics between two time periods, sorted by click delta."
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Gsc
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :site_url, :string, required: true, doc: "Exact GSC property URL from list_properties"
    field :period1_start, :string, required: true, doc: "Period 1 start (YYYY-MM-DD)"
    field :period1_end, :string, required: true, doc: "Period 1 end (YYYY-MM-DD)"
    field :period2_start, :string, required: true, doc: "Period 2 start (YYYY-MM-DD)"
    field :period2_end, :string, required: true, doc: "Period 2 end (YYYY-MM-DD)"
    field :dimensions, :string, doc: "Dimensions to group by (default query)"
    field :limit, :integer, doc: "Top results to compare (default 10)"
  end

  @impl true
  def execute(params, frame) do
    opts = [
      period1_start: params.period1_start,
      period1_end: params.period1_end,
      period2_start: params.period2_start,
      period2_end: params.period2_end,
      dimensions: params[:dimensions] || "query",
      limit: params[:limit] || 10
    ]

    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- Gsc.compare_search_periods(token, params.site_url, opts) do
      {:reply, GoogleTools.ok("Period comparison for #{params.site_url}.", data), frame}
    else
      {:error, {:gsc_error, 404, _}} -> {:reply, GoogleTools.text(GoogleTools.site_not_found(params.site_url)), frame}
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end

defmodule CodeMySpec.McpServers.Gsc.Tools.GetSearchByPageQuery do
  @moduledoc "Search analytics for a specific page, broken down by query."
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Gsc
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :site_url, :string, required: true, doc: "Exact GSC property URL from list_properties"
    field :page_url, :string, required: true, doc: "The specific page URL to analyze"
    field :days, :integer, doc: "Days to look back (default 28)"
    field :row_limit, :integer, doc: "Rows to return (default 20, max 500)"
  end

  @impl true
  def execute(params, frame) do
    opts = [days: params[:days] || 28, row_limit: params[:row_limit] || 20]

    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- Gsc.get_search_by_page_query(token, params.site_url, params.page_url, opts) do
      {:reply, GoogleTools.ok("Queries for #{params.page_url}.", data), frame}
    else
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end

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

defmodule CodeMySpec.McpServers.Gsc.Tools.BatchUrlInspection do
  @moduledoc "Inspect up to 10 URLs at once (one per line)."
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Gsc
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :site_url, :string, required: true, doc: "Exact GSC property URL from list_properties"
    field :urls, :string, required: true, doc: "URLs to inspect, one per line (max 10)"
  end

  @impl true
  def execute(params, frame) do
    urls = split_lines(params.urls)

    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- Gsc.batch_url_inspection(token, params.site_url, urls) do
      {:reply, GoogleTools.ok("Inspected #{data.count} URLs.", data), frame}
    else
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end

  defp split_lines(text) do
    text |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end
end

defmodule CodeMySpec.McpServers.Gsc.Tools.CheckIndexingIssues do
  @moduledoc "Check multiple URLs (one per line, max 10) for indexing problems."
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Gsc
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :site_url, :string, required: true, doc: "Exact GSC property URL from list_properties"
    field :urls, :string, required: true, doc: "URLs to check, one per line (max 10)"
  end

  @impl true
  def execute(params, frame) do
    urls = params.urls |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- Gsc.check_indexing_issues(token, params.site_url, urls) do
      {:reply, GoogleTools.ok("Indexing check for #{params.site_url}.", data), frame}
    else
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end

defmodule CodeMySpec.McpServers.Gsc.Tools.GetSitemaps do
  @moduledoc "List all sitemaps for a Search Console property."
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Gsc
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :site_url, :string, required: true, doc: "Exact GSC property URL from list_properties"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- Gsc.get_sitemaps(token, params.site_url) do
      {:reply, GoogleTools.ok("#{data.count} sitemaps for #{params.site_url}.", data), frame}
    else
      {:error, {:gsc_error, 404, _}} -> {:reply, GoogleTools.text(GoogleTools.site_not_found(params.site_url)), frame}
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end

defmodule CodeMySpec.McpServers.Gsc.Tools.ListSitemapsEnhanced do
  @moduledoc "List sitemaps with detailed info, optionally scoped to a sitemap index."
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Gsc
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :site_url, :string, required: true, doc: "Exact GSC property URL from list_properties"
    field :sitemap_index, :string, doc: "Optional sitemap index URL to list child sitemaps"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- Gsc.list_sitemaps_enhanced(token, params.site_url, params[:sitemap_index]) do
      {:reply, GoogleTools.ok("#{data.count} sitemaps for #{params.site_url}.", data), frame}
    else
      {:error, {:gsc_error, 404, _}} -> {:reply, GoogleTools.text(GoogleTools.site_not_found(params.site_url)), frame}
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end

defmodule CodeMySpec.McpServers.Gsc.Tools.GetSitemapDetails do
  @moduledoc "Get detailed information about a specific sitemap."
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Gsc
  alias CodeMySpec.McpServers.GoogleTools

  schema do
    field :site_url, :string, required: true, doc: "Exact GSC property URL from list_properties"
    field :sitemap_url, :string, required: true, doc: "The full URL of the sitemap to inspect"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- Gsc.get_sitemap_details(token, params.site_url, params.sitemap_url) do
      {:reply, GoogleTools.ok("Details for #{params.sitemap_url}.", data), frame}
    else
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end
end

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

defmodule CodeMySpec.McpServers.Gsc.Tools.ManageSitemaps do
  @moduledoc """
  All-in-one sitemap management: list, details, submit, or delete. Delegates
  to the dedicated tools.
  """
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Google.Gsc
  alias CodeMySpec.McpServers.GoogleTools

  @valid_actions ~w(list details submit delete)

  schema do
    field :site_url, :string, required: true, doc: "Exact GSC property URL from list_properties"
    field :action, :string, required: true, doc: "list, details, submit, or delete"
    field :sitemap_url, :string, doc: "Required for details, submit, delete"
    field :sitemap_index, :string, doc: "Optional sitemap index URL (list action only)"
  end

  @impl true
  def execute(params, frame) do
    action = params.action |> String.downcase() |> String.trim()

    cond do
      action not in @valid_actions ->
        {:reply, GoogleTools.text("Invalid action: #{action}. Use one of: #{Enum.join(@valid_actions, ", ")}"), frame}

      action in ~w(details submit delete) and is_nil(params[:sitemap_url]) ->
        {:reply, GoogleTools.text("The #{action} action requires a sitemap_url parameter."), frame}

      true ->
        dispatch(action, params, frame)
    end
  end

  defp dispatch(action, params, frame) do
    with {:ok, {_scope, token}} <- GoogleTools.resolve(frame, params),
         {:ok, data} <- run(action, token, params) do
      {:reply, GoogleTools.ok("Sitemap #{action} for #{params.site_url}.", data), frame}
    else
      {:reply, _resp, _frame} = reply -> reply
      {:error, reason} -> {:reply, GoogleTools.error(reason), frame}
    end
  end

  defp run("list", token, params),
    do: Gsc.list_sitemaps_enhanced(token, params.site_url, params[:sitemap_index])

  defp run("details", token, params),
    do: Gsc.get_sitemap_details(token, params.site_url, params.sitemap_url)

  defp run("submit", token, params),
    do: Gsc.submit_sitemap(token, params.site_url, params.sitemap_url)

  defp run("delete", token, params) do
    if GoogleTools.destructive_allowed?() do
      Gsc.delete_sitemap(token, params.site_url, params.sitemap_url)
    else
      {:error, :destructive_disabled}
    end
  end
end

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

defmodule CodeMySpec.McpServers.Gsc.Tools.Reauthenticate do
  @moduledoc """
  Guidance for reconnecting the Google account when Search Console calls
  return auth errors.
  """
  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.McpServers.GoogleTools

  schema do
  end

  @impl true
  def execute(_params, frame) do
    {:reply,
     GoogleTools.text(
       "Authentication is managed by CodeMySpec's Google integration, not a local " <>
         "browser flow. Reconnect your Google account (with the Search Console scope " <>
         "https://www.googleapis.com/auth/webmasters) from the integrations settings, " <>
         "then retry."
     ), frame}
  end
end
