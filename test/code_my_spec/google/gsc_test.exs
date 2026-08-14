defmodule CodeMySpec.Google.GscTest do
  @moduledoc """
  Cassette-backed tests for the Search Console Req client. One test per tool
  operation, all replayed from cassettes recorded against the live API
  (property `sc-domain:codemyspec.com`).

  The write tools (add/delete site, submit/delete sitemap) were recorded
  against deliberately throwaway targets — a `__cms_test_delete_me/`
  URL-prefix property and a `__cms_test_sitemap.xml` bogus sitemap — created
  and torn down within the recording run, so the real `sitemap.xml` and the
  `sc-domain` property are never mutated. Re-recording those four requires
  the `webmasters` (read+write) scope and `--seed 0` so the lifecycle runs in
  definition order (add → submit → delete sitemap → delete site).

  Read-only assertions are structural since the recorded data is real and
  changes over time. See `CodeMySpec.GoogleCassetteHelpers` for record/replay.
  """

  use ExUnit.Case, async: true

  import ReqCassette
  import CodeMySpec.GoogleCassetteHelpers

  alias CodeMySpec.Google.Gsc

  @site "sc-domain:codemyspec.com"
  @page "https://codemyspec.com/"
  @page2 "https://codemyspec.com/blog/spec-kit-vs-kiro"
  @sitemap "https://codemyspec.com/sitemap.xml"

  # Throwaway write targets — created and removed within the recording run.
  @prefix_site "https://codemyspec.com/__cms_test_delete_me/"
  @test_sitemap "https://codemyspec.com/__cms_test_sitemap.xml"

  setup do
    on_exit(fn -> Application.put_env(:code_my_spec, Gsc, []) end)
    :ok
  end

  defp run(name, fun) do
    with_cassette name, cassette_opts(), fn plug ->
      with_plug(Gsc, plug, fun)
    end
  end

  # ── Read-only tools (recorded live) ──────────────────────────────────

  test "list_properties parses siteEntry into property list" do
    run("gsc/list_properties", fn ->
      assert {:ok, data} = Gsc.list_properties(token())
      assert is_integer(data.count) and data.count >= 1
      assert Enum.all?(data.properties, &is_binary(&1.site_url))
      assert Enum.any?(data.properties, &(&1.site_url == @site))
    end)
  end

  test "get_site_details returns permission level" do
    run("gsc/get_site_details", fn ->
      assert {:ok, data} = Gsc.get_site_details(token(), @site)
      assert is_binary(data.permission_level)
    end)
  end

  test "get_search_analytics shapes rows by dimension" do
    run("gsc/get_search_analytics", fn ->
      assert {:ok, data} = Gsc.get_search_analytics(token(), @site, days: 28, dimensions: "query", row_limit: 20)
      assert data.dimensions == ["query"]
      assert is_integer(data.row_count)
      assert is_list(data.rows)
      assert Enum.all?(data.rows, &(is_map(&1) and Map.has_key?(&1, "clicks")))
    end)
  end

  test "get_performance_overview returns totals and a daily trend" do
    run("gsc/get_performance_overview", fn ->
      assert {:ok, data} = Gsc.get_performance_overview(token(), @site, 28)
      assert is_integer(data.totals.clicks)
      assert is_integer(data.totals.impressions)
      assert is_list(data.daily_trend)
    end)
  end

  test "get_advanced_search_analytics returns rows with pagination metadata" do
    run("gsc/get_advanced_search_analytics", fn ->
      assert {:ok, data} =
               Gsc.get_advanced_search_analytics(token(), @site, dimensions: "query,page", row_limit: 100)

      assert data.search_type == "WEB"
      assert is_list(data.rows)
      assert is_boolean(data.pagination.has_more)
    end)
  end

  test "get_advanced_search_analytics rejects an invalid data_state without hitting the API" do
    assert {:error, {:invalid_data_state, "weekly"}} =
             Gsc.get_advanced_search_analytics(token(), @site, data_state: "weekly")
  end

  test "compare_search_periods compares two periods" do
    run("gsc/compare_search_periods", fn ->
      opts = [
        period1_start: "2026-04-01",
        period1_end: "2026-04-30",
        period2_start: "2026-05-01",
        period2_end: "2026-05-31",
        dimensions: "query",
        limit: 10
      ]

      assert {:ok, data} = Gsc.compare_search_periods(token(), @site, opts)
      assert is_integer(data.total_items)
      assert is_list(data.comparison)
      assert length(data.comparison) <= 10
    end)
  end

  test "get_search_by_page_query aggregates query rows for a page" do
    run("gsc/get_search_by_page_query", fn ->
      assert {:ok, data} = Gsc.get_search_by_page_query(token(), @site, @page, days: 28)
      assert data.page_url == @page
      assert is_integer(data.row_count)
      assert is_integer(data.totals.clicks)
    end)
  end

  test "inspect_url_enhanced surfaces index status" do
    run("gsc/inspect_url_enhanced", fn ->
      assert {:ok, data} = Gsc.inspect_url_enhanced(token(), @site, @page)
      assert data.page_url == @page
      assert is_binary(data.verdict)
    end)
  end

  test "batch_url_inspection summarizes each URL" do
    run("gsc/batch_url_inspection", fn ->
      assert {:ok, data} = Gsc.batch_url_inspection(token(), @site, [@page, @page2])
      assert data.count == 2
      assert Enum.all?(data.results, &Map.has_key?(&1, :url))
    end)
  end

  test "batch_url_inspection rejects more than 10 URLs before any request" do
    too_many = for i <- 1..11, do: "https://codemyspec.com/#{i}"
    assert {:error, {:too_many_urls, 11}} = Gsc.batch_url_inspection(token(), @site, too_many)
  end

  test "check_indexing_issues categorizes each checked URL" do
    run("gsc/check_indexing_issues", fn ->
      assert {:ok, data} = Gsc.check_indexing_issues(token(), @site, [@page, @page2])
      assert data.summary.total_checked == 2
      assert is_integer(data.summary.indexed)
      assert is_integer(data.summary.not_indexed)
    end)
  end

  test "get_sitemaps lists sitemaps" do
    run("gsc/get_sitemaps", fn ->
      assert {:ok, data} = Gsc.get_sitemaps(token(), @site)
      assert is_integer(data.count)
      assert is_list(data.sitemaps)
    end)
  end

  test "list_sitemaps_enhanced returns detailed sitemap rows" do
    run("gsc/list_sitemaps_enhanced", fn ->
      assert {:ok, data} = Gsc.list_sitemaps_enhanced(token(), @site)
      assert is_integer(data.count)
      assert is_integer(data.pending_count)
      assert is_list(data.sitemaps)
    end)
  end

  test "get_sitemap_details returns content breakdown" do
    run("gsc/get_sitemap_details", fn ->
      assert {:ok, data} = Gsc.get_sitemap_details(token(), @site, @sitemap)
      assert data.sitemap_url == @sitemap
      assert data.type in ["Sitemap", "Index"]
      assert is_list(data.content_breakdown)
    end)
  end

  # ── Write tools (recorded against throwaway targets, in lifecycle order) ──
  #
  # Defined in add → submit → delete-sitemap → delete-site order so that
  # `mix test --seed 0` records a self-contained, self-cleaning lifecycle.

  test "add_site adds a (throwaway) URL-prefix property" do
    run("gsc/add_site", fn ->
      assert {:ok, %{site_url: @prefix_site}} = Gsc.add_site(token(), @prefix_site)
    end)
  end

  test "submit_sitemap submits then confirms via a follow-up GET" do
    run("gsc/submit_sitemap", fn ->
      assert {:ok, data} = Gsc.submit_sitemap(token(), @site, @test_sitemap)
      assert data.submitted == true
      assert is_boolean(data.is_pending)
    end)
  end

  test "delete_sitemap reports deletion" do
    run("gsc/delete_sitemap", fn ->
      assert {:ok, %{sitemap_url: @test_sitemap, deleted: true}} =
               Gsc.delete_sitemap(token(), @site, @test_sitemap)
    end)
  end

  test "delete_site removes the (throwaway) property" do
    run("gsc/delete_site", fn ->
      assert {:ok, %{site_url: @prefix_site, removed: true}} = Gsc.delete_site(token(), @prefix_site)
    end)
  end
end
