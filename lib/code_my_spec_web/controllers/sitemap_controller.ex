defmodule CodeMySpecWeb.SitemapController do
  use CodeMySpecWeb, :controller

  alias CodeMySpec.Content.ContentRepository

  @content_types %{
    blog: "/blog/",
    page: "/pages/",
    landing: "/landing/",
    documentation: "/documentation/"
  }

  @static_routes [
    %{loc: "/", changefreq: "weekly", priority: "1.0"},
    %{loc: "/blog", changefreq: "daily", priority: "0.8"},
    %{loc: "/methodology", changefreq: "monthly", priority: "0.7"},
    %{loc: "/case-studies/metric-flow", changefreq: "monthly", priority: "0.7"}
  ]

  def index(conn, _params) do
    base_url = CodeMySpecWeb.Endpoint.url()

    content_entries =
      @content_types
      |> Enum.flat_map(fn {type, prefix} ->
        ContentRepository.list_published_content(nil, type)
        |> Enum.map(fn content ->
          %{
            loc: prefix <> content.slug,
            lastmod: format_date(content.updated_at),
            changefreq: changefreq_for(type),
            priority: priority_for(type)
          }
        end)
      end)

    entries = @static_routes ++ content_entries

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
            <changefreq>#{entry.changefreq}</changefreq>
            <priority>#{entry.priority}</priority>
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

  defp format_date(%DateTime{} = dt), do: DateTime.to_date(dt) |> Date.to_iso8601()
  defp format_date(_), do: nil

  defp changefreq_for(:blog), do: "weekly"
  defp changefreq_for(_), do: "monthly"

  defp priority_for(:blog), do: "0.7"
  defp priority_for(:landing), do: "0.8"
  defp priority_for(_), do: "0.5"
end
