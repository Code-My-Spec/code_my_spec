defmodule CodeMySpec.Google.Gsc do
  @moduledoc """
  Hand-written `Req` client for the Google Search Console API, ported from
  the [mcp-gsc](https://github.com/AminForou/mcp-gsc) server.

  Each public function corresponds 1:1 to a tool in that server and returns
  `{:ok, data}` where `data` mirrors the JSON structure the Python tool
  emits, or `{:error, reason}`. The `CodeMySpec.McpServers.Gsc` tool modules
  are thin wrappers that resolve a token, call one of these functions, and
  render the result as MCP text.

  ## Auth

  Every function takes a bearer `token` as its first argument so the HTTP
  layer is independently testable with `ReqCassette` (the token is filtered
  out of cassettes). In production the tool layer resolves the token via
  `CodeMySpec.Google.Auth.get_valid_token/1`.

  ## Endpoints

  - Sites / Search Analytics / Sitemaps: `webmasters/v3`
  - URL Inspection: `v1/urlInspection/index:inspect`

  both hosted under `https://searchconsole.googleapis.com`.

  ## Test injection

  Tests set `config :code_my_spec, #{inspect(__MODULE__)}, plug: plug` to
  route `Req` through a `ReqCassette` plug.
  """

  @base "https://searchconsole.googleapis.com"
  @webmasters @base <> "/webmasters/v3"
  @inspect_url @base <> "/v1/urlInspection/index:inspect"

  @type token :: String.t()
  @type result :: {:ok, map()} | {:error, term()}

  # ── Properties ────────────────────────────────────────────────────────

  @doc "Lists all GSC properties the user can access."
  @spec list_properties(token) :: result
  def list_properties(token) do
    with {:ok, body} <- request(:get, @webmasters <> "/sites", token) do
      sites = Map.get(body, "siteEntry", [])

      {:ok,
       %{
         count: length(sites),
         properties:
           Enum.map(sites, fn site ->
             %{
               site_url: Map.get(site, "siteUrl", "Unknown"),
               permission_level: Map.get(site, "permissionLevel", "Unknown")
             }
           end)
       }}
    end
  end

  @doc "Adds a property to Search Console."
  @spec add_site(token, String.t()) :: result
  def add_site(token, site_url) do
    with {:ok, body} <- request(:put, site_path(site_url), token) do
      {:ok, %{site_url: site_url, permission_level: Map.get(body || %{}, "permissionLevel")}}
    end
  end

  @doc "Removes a property from Search Console."
  @spec delete_site(token, String.t()) :: result
  def delete_site(token, site_url) do
    with {:ok, _} <- request(:delete, site_path(site_url), token) do
      {:ok, %{site_url: site_url, removed: true}}
    end
  end

  @doc "Returns verification and ownership details for a property."
  @spec get_site_details(token, String.t()) :: result
  def get_site_details(token, site_url) do
    with {:ok, info} <- request(:get, site_path(site_url), token) do
      result =
        %{site_url: site_url, permission_level: Map.get(info, "permissionLevel", "Unknown")}
        |> maybe_put_verification(info)
        |> maybe_put_ownership(info)

      {:ok, result}
    end
  end

  defp maybe_put_verification(result, %{"siteVerificationInfo" => v}) do
    Map.put(result, :verification, %{
      state: Map.get(v, "verificationState", "Unknown"),
      verified_user: Map.get(v, "verifiedUser"),
      method: Map.get(v, "verificationMethod")
    })
  end

  defp maybe_put_verification(result, _), do: result

  defp maybe_put_ownership(result, %{"ownershipInfo" => o}) do
    Map.put(result, :ownership, %{
      owner: Map.get(o, "owner", "Unknown"),
      verification_method: Map.get(o, "verificationMethod")
    })
  end

  defp maybe_put_ownership(result, _), do: result

  # ── Search Analytics ──────────────────────────────────────────────────

  @doc """
  Top queries/pages with clicks, impressions, CTR, and position over the
  last `days`. `dimensions` is a comma string (e.g. `"query,page"`).
  """
  @spec get_search_analytics(token, String.t(), keyword()) :: result
  def get_search_analytics(token, site_url, opts \\ []) do
    days = Keyword.get(opts, :days, 28)
    dimensions = Keyword.get(opts, :dimensions, "query")
    row_limit = Keyword.get(opts, :row_limit, 20)
    {start_date, end_date} = default_range(days)
    dimension_list = split_dimensions(dimensions)

    body = %{
      "startDate" => start_date,
      "endDate" => end_date,
      "dimensions" => dimension_list,
      "rowLimit" => row_limit |> max(1) |> min(500),
      "dataState" => data_state()
    }

    with {:ok, response} <- query(token, site_url, body) do
      rows = shape_rows(Map.get(response, "rows", []), dimension_list)

      {:ok,
       %{
         site_url: site_url,
         date_range: %{start: start_date, end: end_date, days: days},
         dimensions: dimension_list,
         row_count: length(rows),
         rows: rows
       }}
    end
  end

  @doc "Totals + daily trend for the last `days`."
  @spec get_performance_overview(token, String.t(), integer()) :: result
  def get_performance_overview(token, site_url, days \\ 28) do
    {start_date, end_date} = default_range(days)

    totals_body = %{
      "startDate" => start_date,
      "endDate" => end_date,
      "dimensions" => [],
      "rowLimit" => 1,
      "dataState" => data_state()
    }

    date_body = %{
      "startDate" => start_date,
      "endDate" => end_date,
      "dimensions" => ["date"],
      "rowLimit" => days,
      "dataState" => data_state()
    }

    with {:ok, total_response} <- query(token, site_url, totals_body),
         {:ok, date_response} <- query(token, site_url, date_body) do
      case Map.get(total_response, "rows", []) do
        [] ->
          {:ok, %{site_url: site_url, empty: true, days: days}}

        [totals_row | _] ->
          totals = %{
            clicks: Map.get(totals_row, "clicks", 0),
            impressions: Map.get(totals_row, "impressions", 0),
            ctr: round4(Map.get(totals_row, "ctr", 0)),
            position: round1(Map.get(totals_row, "position", 0))
          }

          daily_trend =
            date_response
            |> Map.get("rows", [])
            |> Enum.sort_by(fn row -> hd(Map.get(row, "keys", [""])) end)
            |> Enum.map(fn row ->
              %{
                date: hd(Map.get(row, "keys", [nil])),
                clicks: Map.get(row, "clicks", 0),
                impressions: Map.get(row, "impressions", 0),
                ctr: round4(Map.get(row, "ctr", 0)),
                position: round1(Map.get(row, "position", 0))
              }
            end)

          {:ok,
           %{
             site_url: site_url,
             date_range: %{start: start_date, end: end_date, days: days},
             totals: totals,
             daily_trend: daily_trend
           }}
      end
    end
  end

  @doc """
  Advanced search analytics with sorting, multi-dimension filtering, search
  type, and pagination. `opts` keys mirror the upstream tool arguments.
  """
  @spec get_advanced_search_analytics(token, String.t(), keyword()) :: result
  def get_advanced_search_analytics(token, site_url, opts \\ []) do
    {start_date, end_date} =
      case {opts[:start_date], opts[:end_date]} do
        {nil, nil} -> default_range(28)
        {nil, e} -> {elem(default_range(28), 0), e}
        {s, nil} -> {s, Date.to_iso8601(Date.utc_today())}
        {s, e} -> {s, e}
      end

    dimensions = Keyword.get(opts, :dimensions, "query")
    dimension_list = split_dimensions(dimensions)
    search_type = Keyword.get(opts, :search_type, "WEB")
    row_limit = Keyword.get(opts, :row_limit, 1000)
    start_row = Keyword.get(opts, :start_row, 0)
    sort_by = Keyword.get(opts, :sort_by, "clicks")
    sort_direction = Keyword.get(opts, :sort_direction, "descending")
    resolved_data_state = (Keyword.get(opts, :data_state) || data_state()) |> to_lower_trim()

    with :ok <- validate_data_state(resolved_data_state),
         {:ok, active_filters} <- build_filters(opts) do
      body =
        %{
          "startDate" => start_date,
          "endDate" => end_date,
          "dimensions" => dimension_list,
          "rowLimit" => min(row_limit, 25_000),
          "startRow" => start_row,
          "searchType" => String.upcase(search_type),
          "dataState" => resolved_data_state
        }
        |> maybe_put_order_by(sort_by, sort_direction)
        |> maybe_put_filter_groups(active_filters)

      with {:ok, response} <- query(token, site_url, body) do
        raw_rows = Map.get(response, "rows", [])
        rows = shape_rows(raw_rows, dimension_list)
        has_more = length(raw_rows) == row_limit

        {:ok,
         %{
           site_url: site_url,
           date_range: %{start: start_date, end: end_date},
           search_type: search_type,
           dimensions: dimension_list,
           filters_applied: active_filters,
           pagination: %{
             start_row: start_row,
             row_count: length(rows),
             has_more: has_more,
             next_start_row: if(has_more, do: start_row + row_limit, else: nil)
           },
           rows: rows
         }}
      end
    end
  end

  @doc "Compares two time periods, sorted by absolute click delta."
  @spec compare_search_periods(token, String.t(), keyword()) :: result
  def compare_search_periods(token, site_url, opts) do
    dimension_list = split_dimensions(Keyword.get(opts, :dimensions, "query"))
    limit = Keyword.get(opts, :limit, 10)

    p1_body =
      period_body(opts[:period1_start], opts[:period1_end], dimension_list)

    p2_body =
      period_body(opts[:period2_start], opts[:period2_end], dimension_list)

    with {:ok, p1_resp} <- query(token, site_url, p1_body),
         {:ok, p2_resp} <- query(token, site_url, p2_body) do
      p1_rows = Map.get(p1_resp, "rows", [])
      p2_rows = Map.get(p2_resp, "rows", [])

      p1_data = Map.new(p1_rows, fn row -> {Map.get(row, "keys", []), row} end)
      p2_data = Map.new(p2_rows, fn row -> {Map.get(row, "keys", []), row} end)

      all_keys = MapSet.union(MapSet.new(Map.keys(p1_data)), MapSet.new(Map.keys(p2_data)))

      comparison =
        all_keys
        |> Enum.map(&compare_key(&1, p1_data, p2_data))
        |> Enum.sort_by(fn item -> abs(item.click_diff) end, :desc)

      showing = Enum.take(comparison, limit)

      {:ok,
       %{
         site_url: site_url,
         period1: %{start: opts[:period1_start], end: opts[:period1_end]},
         period2: %{start: opts[:period2_start], end: opts[:period2_end]},
         dimensions: dimension_list,
         total_items: length(comparison),
         showing: length(showing),
         comparison: showing
       }}
    end
  end

  @doc "Queries driving traffic to a specific page, broken down by query."
  @spec get_search_by_page_query(token, String.t(), String.t(), keyword()) :: result
  def get_search_by_page_query(token, site_url, page_url, opts \\ []) do
    days = Keyword.get(opts, :days, 28)
    row_limit = Keyword.get(opts, :row_limit, 20)
    {start_date, end_date} = default_range(days)

    body = %{
      "startDate" => start_date,
      "endDate" => end_date,
      "dimensions" => ["query"],
      "dimensionFilterGroups" => [
        %{
          "filters" => [
            %{"dimension" => "page", "operator" => "equals", "expression" => page_url}
          ]
        }
      ],
      "rowLimit" => row_limit |> max(1) |> min(500),
      "orderBy" => [%{"metric" => "CLICK_COUNT", "direction" => "descending"}],
      "dataState" => data_state()
    }

    with {:ok, response} <- query(token, site_url, body) do
      rows =
        response
        |> Map.get("rows", [])
        |> Enum.map(fn row ->
          %{
            query: List.first(Map.get(row, "keys", ["Unknown"])),
            clicks: Map.get(row, "clicks", 0),
            impressions: Map.get(row, "impressions", 0),
            ctr: round4(Map.get(row, "ctr", 0)),
            position: round1(Map.get(row, "position", 0))
          }
        end)

      total_clicks = Enum.sum(Enum.map(rows, & &1.clicks))
      total_impressions = Enum.sum(Enum.map(rows, & &1.impressions))

      {:ok,
       %{
         site_url: site_url,
         page_url: page_url,
         date_range: %{start: start_date, end: end_date, days: days},
         totals: %{
           clicks: total_clicks,
           impressions: total_impressions,
           avg_ctr:
             if(total_impressions > 0, do: round4(total_clicks / total_impressions), else: 0)
         },
         row_count: length(rows),
         rows: rows
       }}
    end
  end

  @doc "Low-level `searchAnalytics.query`, returning the raw API response."
  @spec query(token, String.t(), map()) :: result
  def query(token, site_url, body) do
    request(:post, site_path(site_url) <> "/searchAnalytics/query", token, json: body)
  end

  # ── URL Inspection ────────────────────────────────────────────────────

  @doc "Raw URL inspection for a single page."
  @spec inspect_url(token, String.t(), String.t()) :: result
  def inspect_url(token, site_url, page_url) do
    request(:post, @inspect_url, token,
      json: %{"inspectionUrl" => page_url, "siteUrl" => site_url}
    )
  end

  @doc "Shaped crawl/index status + rich-results for a single URL."
  @spec inspect_url_enhanced(token, String.t(), String.t()) :: result
  def inspect_url_enhanced(token, site_url, page_url) do
    with {:ok, response} <- inspect_url(token, site_url, page_url) do
      case Map.get(response, "inspectionResult") do
        nil ->
          {:ok, %{page_url: page_url, empty: true}}

        inspection ->
          index_status = Map.get(inspection, "indexStatusResult", %{})

          rich_results =
            case Map.get(inspection, "richResultsResult") do
              nil ->
                nil

              rich ->
                %{
                  verdict: Map.get(rich, "verdict", "UNKNOWN"),
                  detected_types:
                    rich
                    |> Map.get("detectedItems", [])
                    |> Enum.map(&Map.get(&1, "richResultType", "Unknown")),
                  issues:
                    rich
                    |> Map.get("richResultsIssues", [])
                    |> Enum.map(
                      &%{severity: Map.get(&1, "severity"), message: Map.get(&1, "message")}
                    )
                }
            end

          {:ok,
           %{
             page_url: page_url,
             site_url: site_url,
             inspection_result_link: Map.get(inspection, "inspectionResultLink"),
             verdict: Map.get(index_status, "verdict", "UNKNOWN"),
             coverage_state: Map.get(index_status, "coverageState"),
             last_crawled: Map.get(index_status, "lastCrawlTime"),
             page_fetch_state: Map.get(index_status, "pageFetchState"),
             robots_txt_state: Map.get(index_status, "robotsTxtState"),
             indexing_state: Map.get(index_status, "indexingState"),
             google_canonical: Map.get(index_status, "googleCanonical"),
             user_canonical: Map.get(index_status, "userCanonical"),
             crawled_as: Map.get(index_status, "crawledAs"),
             referring_urls: Enum.take(Map.get(index_status, "referringUrls", []), 5),
             rich_results: rich_results
           }}
      end
    end
  end

  @doc "Inspects up to 10 URLs, returning a compact per-URL summary."
  @spec batch_url_inspection(token, String.t(), [String.t()]) :: result
  def batch_url_inspection(token, site_url, urls) when is_list(urls) do
    cond do
      urls == [] ->
        {:error, :no_urls}

      length(urls) > 10 ->
        {:error, {:too_many_urls, length(urls)}}

      true ->
        results = Enum.map(urls, &inspect_url_summary(token, site_url, &1))
        {:ok, %{site_url: site_url, count: length(results), results: results}}
    end
  end

  defp inspect_url_summary(token, site_url, page_url) do
    case inspect_url(token, site_url, page_url) do
      {:ok, %{"inspectionResult" => inspection}} ->
        index_status = Map.get(inspection, "indexStatusResult", %{})

        %{
          url: page_url,
          verdict: Map.get(index_status, "verdict", "UNKNOWN"),
          coverage_state: Map.get(index_status, "coverageState", "Unknown"),
          last_crawled: Map.get(index_status, "lastCrawlTime", "Never"),
          rich_results: rich_results_summary(inspection)
        }

      {:ok, _} ->
        %{url: page_url, error: "No inspection data found"}

      {:error, reason} ->
        %{url: page_url, error: inspect(reason)}
    end
  end

  defp rich_results_summary(inspection) do
    case Map.get(inspection, "richResultsResult") do
      %{"verdict" => "PASS", "detectedItems" => [_ | _] = items} ->
        Enum.map_join(items, ", ", &Map.get(&1, "richResultType", "Unknown"))

      _ ->
        "None"
    end
  end

  @doc "Categorizes indexing problems across up to 10 URLs."
  @spec check_indexing_issues(token, String.t(), [String.t()]) :: result
  def check_indexing_issues(token, site_url, urls) when is_list(urls) do
    cond do
      urls == [] ->
        {:error, :no_urls}

      length(urls) > 10 ->
        {:error, {:too_many_urls, length(urls)}}

      true ->
        summary =
          Enum.reduce(
            urls,
            %{
              not_indexed: [],
              canonical_issues: [],
              robots_blocked: [],
              fetch_issues: [],
              indexed: []
            },
            fn page_url, acc -> categorize_url(token, site_url, page_url, acc) end
          )

        {:ok,
         %{
           site_url: site_url,
           summary: %{
             total_checked: length(urls),
             indexed: length(summary.indexed),
             not_indexed: length(summary.not_indexed),
             canonical_issues: length(summary.canonical_issues),
             robots_blocked: length(summary.robots_blocked),
             fetch_issues: length(summary.fetch_issues)
           },
           issues: %{
             not_indexed: Enum.reverse(summary.not_indexed),
             canonical_issues: Enum.reverse(summary.canonical_issues),
             robots_blocked: Enum.reverse(summary.robots_blocked),
             fetch_issues: Enum.reverse(summary.fetch_issues)
           },
           indexed_urls: Enum.reverse(summary.indexed)
         }}
    end
  end

  defp categorize_url(token, site_url, page_url, acc) do
    case inspect_url(token, site_url, page_url) do
      {:ok, %{"inspectionResult" => inspection}} ->
        index_status = Map.get(inspection, "indexStatusResult", %{})

        acc
        |> flag_indexed(page_url, index_status)
        |> flag_canonical_mismatch(page_url, index_status)
        |> flag_robots_blocked(page_url, index_status)
        |> flag_fetch_issue(page_url, index_status)

      {:ok, _} ->
        update(acc, :not_indexed, "#{page_url} - No inspection data found")

      {:error, reason} ->
        update(acc, :not_indexed, "#{page_url} - Error: #{inspect(reason)}")
    end
  end

  defp flag_indexed(acc, page_url, index_status) do
    verdict = Map.get(index_status, "verdict", "UNKNOWN")
    coverage = Map.get(index_status, "coverageState", "Unknown")
    lower = String.downcase(coverage)

    if verdict != "PASS" or String.contains?(lower, "not indexed") or
         String.contains?(lower, "excluded") do
      update(acc, :not_indexed, "#{page_url} - #{coverage}")
    else
      update(acc, :indexed, page_url)
    end
  end

  defp flag_canonical_mismatch(acc, page_url, index_status) do
    google_canonical = Map.get(index_status, "googleCanonical", "")
    user_canonical = Map.get(index_status, "userCanonical", "")

    if google_canonical != "" and user_canonical != "" and
         google_canonical != user_canonical do
      update(
        acc,
        :canonical_issues,
        "#{page_url} - Google chose: #{google_canonical} instead of user-declared: #{user_canonical}"
      )
    else
      acc
    end
  end

  defp flag_robots_blocked(acc, page_url, index_status) do
    if Map.get(index_status, "robotsTxtState", "") == "BLOCKED" do
      update(acc, :robots_blocked, page_url)
    else
      acc
    end
  end

  defp flag_fetch_issue(acc, page_url, index_status) do
    fetch_state = Map.get(index_status, "pageFetchState", "")

    if fetch_state != "SUCCESSFUL" and fetch_state != "" do
      update(acc, :fetch_issues, "#{page_url} - #{fetch_state}")
    else
      acc
    end
  end

  defp update(acc, key, value), do: Map.update!(acc, key, &[value | &1])

  # ── Sitemaps ──────────────────────────────────────────────────────────

  @doc "Lists sitemaps for a property (compact view)."
  @spec get_sitemaps(token, String.t()) :: result
  def get_sitemaps(token, site_url) do
    with {:ok, body} <- request(:get, site_path(site_url) <> "/sitemaps", token) do
      sitemaps =
        body
        |> Map.get("sitemap", [])
        |> Enum.map(fn sitemap ->
          errors = to_int(Map.get(sitemap, "errors", 0))
          warnings = to_int(Map.get(sitemap, "warnings", 0))

          status =
            cond do
              errors > 0 -> "Has errors"
              warnings > 0 -> "Has warnings"
              true -> "Valid"
            end

          %{
            path: Map.get(sitemap, "path", "Unknown"),
            last_downloaded: Map.get(sitemap, "lastDownloaded"),
            status: status,
            indexed_urls: web_content_submitted(sitemap),
            errors: errors,
            warnings: warnings
          }
        end)

      {:ok, %{site_url: site_url, count: length(sitemaps), sitemaps: sitemaps}}
    end
  end

  @doc "Lists sitemaps with full detail, optionally scoped to an index."
  @spec list_sitemaps_enhanced(token, String.t(), String.t() | nil) :: result
  def list_sitemaps_enhanced(token, site_url, sitemap_index \\ nil) do
    opts =
      case sitemap_index do
        nil -> []
        idx -> [params: [sitemapIndex: idx]]
      end

    with {:ok, body} <- request(:get, site_path(site_url) <> "/sitemaps", token, opts) do
      sitemaps =
        body
        |> Map.get("sitemap", [])
        |> Enum.map(fn sitemap ->
          %{
            path: Map.get(sitemap, "path", "Unknown"),
            last_submitted: Map.get(sitemap, "lastSubmitted"),
            last_downloaded: Map.get(sitemap, "lastDownloaded"),
            type: if(Map.get(sitemap, "isSitemapsIndex", false), do: "Index", else: "Sitemap"),
            is_pending: Map.get(sitemap, "isPending", false),
            url_count: web_content_submitted(sitemap),
            errors: to_int(Map.get(sitemap, "errors", 0)),
            warnings: to_int(Map.get(sitemap, "warnings", 0))
          }
        end)

      {:ok,
       %{
         site_url: site_url,
         sitemap_index: sitemap_index,
         count: length(sitemaps),
         pending_count: Enum.count(sitemaps, & &1.is_pending),
         sitemaps: sitemaps
       }}
    end
  end

  @doc "Detailed info about a single sitemap."
  @spec get_sitemap_details(token, String.t(), String.t()) :: result
  def get_sitemap_details(token, site_url, sitemap_url) do
    with {:ok, details} <-
           request(:get, site_path(site_url) <> "/sitemaps/" <> encode(sitemap_url), token) do
      is_index = Map.get(details, "isSitemapsIndex", false)

      content_breakdown =
        details
        |> Map.get("contents", [])
        |> Enum.map(fn content ->
          %{
            type: content |> Map.get("type", "unknown") |> String.upcase(),
            submitted: Map.get(content, "submitted", 0),
            indexed: Map.get(content, "indexed")
          }
        end)

      {:ok,
       %{
         sitemap_url: sitemap_url,
         site_url: site_url,
         type: if(is_index, do: "Index", else: "Sitemap"),
         status: if(Map.get(details, "isPending", false), do: "pending", else: "processed"),
         last_submitted: Map.get(details, "lastSubmitted"),
         last_downloaded: Map.get(details, "lastDownloaded"),
         errors: to_int(Map.get(details, "errors", 0)),
         warnings: to_int(Map.get(details, "warnings", 0)),
         content_breakdown: content_breakdown,
         is_index: is_index
       }}
    end
  end

  @doc "Submits (or resubmits) a sitemap."
  @spec submit_sitemap(token, String.t(), String.t()) :: result
  def submit_sitemap(token, site_url, sitemap_url) do
    path = site_path(site_url) <> "/sitemaps/" <> encode(sitemap_url)

    with {:ok, _} <- request(:put, path, token) do
      case request(:get, path, token) do
        {:ok, details} ->
          {:ok,
           %{
             sitemap_url: sitemap_url,
             submitted: true,
             last_submitted: Map.get(details, "lastSubmitted"),
             is_pending: Map.get(details, "isPending", true)
           }}

        {:error, _} ->
          {:ok, %{sitemap_url: sitemap_url, submitted: true}}
      end
    end
  end

  @doc "Deletes (unsubmits) a sitemap."
  @spec delete_sitemap(token, String.t(), String.t()) :: result
  def delete_sitemap(token, site_url, sitemap_url) do
    path = site_path(site_url) <> "/sitemaps/" <> encode(sitemap_url)

    with {:ok, _} <- request(:delete, path, token) do
      {:ok, %{sitemap_url: sitemap_url, deleted: true}}
    end
  end

  # ── Core request ──────────────────────────────────────────────────────

  defp request(method, url, token, opts \\ []) do
    headers =
      [
        {"authorization", "Bearer #{token}"},
        {"accept", "application/json"},
        {"user-agent", "CodeMySpec"}
      ] ++ content_length_header(method, opts)

    req_opts =
      [method: method, url: url, headers: headers]
      |> Keyword.merge(opts)
      |> Keyword.merge(plug_opt())

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, normalize_body(body)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:gsc_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_body(""), do: %{}
  defp normalize_body(nil), do: %{}
  defp normalize_body(body) when is_map(body), do: body
  defp normalize_body(body), do: body

  # A bodyless PUT (sites.add, sitemaps.submit) must still carry a
  # Content-Length, or Google's edge returns 411 ("requires a Content-length
  # header"). Req omits the header when there's no body, so set it explicitly.
  defp content_length_header(:put, opts) do
    if Keyword.has_key?(opts, :json) or Keyword.has_key?(opts, :body) do
      []
    else
      [{"content-length", "0"}]
    end
  end

  defp content_length_header(_method, _opts), do: []

  # ── Helpers ───────────────────────────────────────────────────────────

  defp site_path(site_url), do: @webmasters <> "/sites/" <> encode(site_url)

  # Full percent-encoding of a path segment (scheme, slashes and all),
  # matching what the Google API client does for siteUrl/feedpath.
  defp encode(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp split_dimensions(dimensions) do
    dimensions
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp default_range(days) do
    today = Date.utc_today()
    {Date.to_iso8601(Date.add(today, -days)), Date.to_iso8601(today)}
  end

  defp data_state do
    Application.get_env(:code_my_spec, __MODULE__, [])
    |> Keyword.get(:data_state, "all")
  end

  defp period_body(start_date, end_date, dimension_list) do
    %{
      "startDate" => start_date,
      "endDate" => end_date,
      "dimensions" => dimension_list,
      "rowLimit" => 1000,
      "dataState" => data_state()
    }
  end

  defp shape_rows(rows, dimension_list) do
    Enum.map(rows, fn row ->
      keys = Map.get(row, "keys", [])

      dimension_list
      |> Enum.with_index()
      |> Map.new(fn {dim, i} -> {dim, Enum.at(keys, i)} end)
      |> Map.merge(%{
        "clicks" => Map.get(row, "clicks", 0),
        "impressions" => Map.get(row, "impressions", 0),
        "ctr" => round4(Map.get(row, "ctr", 0)),
        "position" => round1(Map.get(row, "position", 0))
      })
    end)
  end

  defp compare_key(key, p1_data, p2_data) do
    p1 = Map.get(p1_data, key, %{})
    p2 = Map.get(p2_data, key, %{})
    p1_clicks = Map.get(p1, "clicks", 0)
    p2_clicks = Map.get(p2, "clicks", 0)
    p1_imp = Map.get(p1, "impressions", 0)
    p2_imp = Map.get(p2, "impressions", 0)
    click_diff = p2_clicks - p1_clicks
    imp_diff = p2_imp - p1_imp

    %{
      key: key,
      p1_clicks: p1_clicks,
      p2_clicks: p2_clicks,
      click_diff: click_diff,
      click_pct: pct(click_diff, p1_clicks),
      p1_impressions: p1_imp,
      p2_impressions: p2_imp,
      imp_diff: imp_diff,
      imp_pct: pct(imp_diff, p1_imp),
      p1_ctr: round4(Map.get(p1, "ctr", 0)),
      p2_ctr: round4(Map.get(p2, "ctr", 0)),
      ctr_diff: round4(Map.get(p2, "ctr", 0) - Map.get(p1, "ctr", 0)),
      p1_position: round1(Map.get(p1, "position", 0)),
      p2_position: round1(Map.get(p2, "position", 0)),
      # lower position is better, so p1 - p2
      position_diff: round1(Map.get(p1, "position", 0) - Map.get(p2, "position", 0))
    }
  end

  defp pct(_diff, 0), do: nil
  defp pct(diff, base) when base > 0, do: round1(diff / base * 100)
  defp pct(_diff, _base), do: nil

  defp maybe_put_order_by(body, sort_by, sort_direction) do
    metric_map = %{
      "clicks" => "CLICK_COUNT",
      "impressions" => "IMPRESSION_COUNT",
      "ctr" => "CTR",
      "position" => "POSITION"
    }

    case Map.get(metric_map, sort_by) do
      nil ->
        body

      metric ->
        Map.put(body, "orderBy", [
          %{"metric" => metric, "direction" => String.downcase(sort_direction)}
        ])
    end
  end

  defp maybe_put_filter_groups(body, []), do: body

  defp maybe_put_filter_groups(body, filters) do
    Map.put(body, "dimensionFilterGroups", [%{"filters" => filters}])
  end

  # Multi-filter JSON takes priority over the single-filter params, mirroring
  # the upstream tool.
  defp build_filters(opts) do
    cond do
      filters = opts[:filters] ->
        validate_filters(filters)

      opts[:filter_dimension] && opts[:filter_expression] ->
        {:ok,
         [
           %{
             "dimension" => opts[:filter_dimension],
             "operator" => Keyword.get(opts, :filter_operator, "contains"),
             "expression" => opts[:filter_expression]
           }
         ]}

      true ->
        {:ok, []}
    end
  end

  defp validate_filters(filters) when is_list(filters) and filters != [] do
    if Enum.all?(filters, fn f ->
         Map.has_key?(f, "dimension") and Map.has_key?(f, "operator") and
           Map.has_key?(f, "expression")
       end) do
      {:ok, filters}
    else
      {:error, :invalid_filter_shape}
    end
  end

  defp validate_filters(_), do: {:error, :invalid_filters}

  defp validate_data_state(state) when state in ["all", "final"], do: :ok
  defp validate_data_state(state), do: {:error, {:invalid_data_state, state}}

  defp web_content_submitted(sitemap) do
    sitemap
    |> Map.get("contents", [])
    |> Enum.find_value(fn content ->
      if Map.get(content, "type") == "web", do: Map.get(content, "submitted")
    end)
  end

  defp to_lower_trim(s) when is_binary(s), do: s |> String.downcase() |> String.trim()
  defp to_lower_trim(s), do: s

  defp to_int(n) when is_integer(n), do: n
  defp to_int(n) when is_float(n), do: trunc(n)

  defp to_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> i
      :error -> 0
    end
  end

  defp to_int(_), do: 0

  defp round4(n) when is_number(n), do: Float.round(n / 1, 4)
  defp round4(_), do: 0.0
  defp round1(n) when is_number(n), do: Float.round(n / 1, 1)
  defp round1(_), do: 0.0

  defp plug_opt do
    case Application.get_env(:code_my_spec, __MODULE__, []) |> Keyword.get(:plug) do
      nil -> []
      plug -> [plug: plug]
    end
  end
end
