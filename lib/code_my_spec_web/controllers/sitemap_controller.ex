defmodule CodeMySpecWeb.SitemapController do
  use CodeMySpecWeb, :controller

  alias CodeMySpec.Content.ContentRepository

  @content_types %{
    blog: "/blog/",
    page: "/pages/",
    landing: "/landing/",
    documentation: "/documentation/"
  }

  @static_locs ["/", "/blog", "/methodology", "/case-studies/metric-flow", "/author/john-davenport"]
  @deploy_date Date.utc_today() |> Date.to_iso8601()

  def index(conn, _params) do
    base_url = CodeMySpecWeb.Endpoint.url()

    static_entries = Enum.map(@static_locs, &%{loc: &1, lastmod: @deploy_date})

    content_entries =
      @content_types
      |> Enum.flat_map(fn {type, prefix} ->
        ContentRepository.list_published_content(nil, type)
        |> Enum.map(fn content ->
          %{
            loc: prefix <> content.slug,
            lastmod: format_date(content.publish_at) || format_date(content.updated_at)
          }
        end)
      end)

    entries = static_entries ++ content_entries

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

  defp format_date(%DateTime{} = dt), do: DateTime.to_date(dt) |> Date.to_iso8601()
  defp format_date(_), do: nil
end
