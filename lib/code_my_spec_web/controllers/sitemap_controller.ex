defmodule CodeMySpecWeb.SitemapController do
  use CodeMySpecWeb, :controller

  alias CodeMySpec.Content.ContentRepository
  alias CodeMySpecWeb.Plugs.LegacyRedirects

  @content_types %{
    blog: "/blog/",
    page: "/pages/",
    landing: "/landing/",
    documentation: "/documentation/"
  }

  @static_locs [
    "/",
    "/product",
    "/agents",
    "/design-system",
    "/behavior",
    "/vibe-coding-rebuild",
    "/developers",
    "/install",
    "/pricing",
    "/blog",
    "/methodology",
    "/case-studies",
    "/case-studies/metric-flow",
    "/case-studies/market-my-spec",
    "/case-studies/cleaner-crm",
    "/case-studies/keel",
    "/case-studies/legwork",
    "/case-studies/ear-witness",
    "/case-studies/broken-oaths",
    "/author/john-davenport",
    "/pages/founder-story",
    "/pages/about",
    "/pages",
    "/documentation"
  ]

  def index(conn, _params) do
    base_url = CodeMySpecWeb.Endpoint.url()

    all_content =
      @content_types
      |> Enum.flat_map(fn {type, _prefix} ->
        ContentRepository.list_published_content(nil, type)
      end)

    # Static pages get no lastmod: stamping them with a borrowed "latest
    # content" date reads as sitewide date churn to crawlers.
    static_entries = Enum.map(@static_locs, &%{loc: &1})

    content_entries =
      @content_types
      |> Enum.flat_map(fn {type, prefix} ->
        all_content
        |> Enum.filter(fn c ->
          # Match on type and verify content is actually accessible at its public URL.
          c.content_type == type and
            ContentRepository.get_content_by_slug(nil, c.slug, type) != nil
        end)
        |> Enum.map(fn content ->
          # publish_at is the immutable per-post timestamp from YAML; updated_at is
          # auto-managed by Ecto and tends to collapse to deploy time, which gives
          # Google a uniform lastmod and suppresses re-crawl.
          %{
            loc: prefix <> content.slug,
            lastmod: format_date(content.publish_at) || format_date(content.updated_at)
          }
        end)
      end)

    static_paths = MapSet.new(@static_locs)
    redirect_paths = LegacyRedirects.redirect_paths()

    entries =
      static_entries ++
        Enum.reject(content_entries, fn entry ->
          MapSet.member?(static_paths, entry.loc) or
            MapSet.member?(redirect_paths, entry.loc)
        end)

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, render_xml(base_url, entries))
  end

  defp render_xml(base_url, entries) do
    urls =
      Enum.map_join(entries, "\n", fn entry ->
        lastmod =
          if entry[:lastmod],
            do: "\n    <lastmod>#{entry.lastmod}</lastmod>",
            else: ""

        """
          <url>
            <loc>#{base_url}#{entry.loc}</loc>#{lastmod}
          </url>\
        """
      end)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
    #{urls}
    </urlset>
    """
  end

  defp format_date(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_date(_), do: nil
end
