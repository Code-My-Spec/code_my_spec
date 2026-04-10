defmodule CodeMySpecWeb.SitemapController do
  use CodeMySpecWeb, :controller

  alias CodeMySpec.Content.ContentRepository

  @content_types %{
    blog: "/blog/",
    page: "/pages/",
    landing: "/landing/",
    documentation: "/documentation/"
  }

  @static_locs ["/", "/blog", "/methodology", "/case-studies/metric-flow", "/author/john-davenport", "/pages/founder-story", "/pages/about", "/pages", "/documentation"]

  def index(conn, _params) do
    base_url = CodeMySpecWeb.Endpoint.url()

    # Use the most recent content date as fallback for static pages
    all_content =
      @content_types
      |> Enum.flat_map(fn {type, _prefix} ->
        ContentRepository.list_published_content(nil, type)
      end)

    latest_date =
      all_content
      |> Enum.map(fn c -> c.updated_at || c.publish_at end)
      |> Enum.reject(&is_nil/1)
      |> Enum.max(DateTime, fn -> DateTime.utc_now() end)
      |> format_date()

    static_entries = Enum.map(@static_locs, &%{loc: &1, lastmod: latest_date})

    content_entries =
      @content_types
      |> Enum.flat_map(fn {type, prefix} ->
        all_content
        |> Enum.filter(fn c -> c.content_type == type end)
        |> Enum.filter(fn c ->
          # Verify content is actually accessible at its public URL
          ContentRepository.get_content_by_slug(nil, c.slug, type) != nil
        end)
        |> Enum.map(fn content ->
          %{
            loc: prefix <> content.slug,
            lastmod: format_date(content.updated_at) || format_date(content.publish_at)
          }
        end)
      end)

    static_paths = MapSet.new(@static_locs)

    entries =
      static_entries ++
        Enum.reject(content_entries, fn entry -> MapSet.member?(static_paths, entry.loc) end)

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
