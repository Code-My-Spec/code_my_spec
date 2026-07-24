defmodule CodeMySpecWeb.FeedController do
  use CodeMySpecWeb, :controller

  alias CodeMySpec.Content.ContentRepository

  def blog(conn, _params) do
    base_url = CodeMySpecWeb.Endpoint.url()

    posts =
      ContentRepository.list_published_content(nil, :blog)
      |> Enum.sort_by(& &1.publish_at, {:desc, DateTime})

    conn
    |> put_resp_content_type("application/atom+xml")
    |> send_resp(200, render_atom(base_url, posts))
  end

  defp render_atom(base_url, posts) do
    # Feed-level <updated> mirrors the newest entry rather than request time,
    # so the feed doesn't read as changed on every fetch.
    updated =
      case posts do
        [newest | _] -> format_date(newest.publish_at)
        [] -> nil
      end

    entries = Enum.map_join(posts, "\n", &render_entry(base_url, &1))

    """
    <?xml version="1.0" encoding="utf-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title>CodeMySpec Blog</title>
      <subtitle>Insights on structured AI development, avoiding LLM-generated technical debt, and building production-ready Phoenix applications.</subtitle>
      <id>#{base_url}/blog</id>
      <link href="#{base_url}/blog"/>
      <link rel="self" href="#{base_url}/blog/feed.xml"/>
      #{if updated, do: "<updated>#{updated}</updated>", else: ""}
      <author>
        <name>John Davenport</name>
        <uri>#{base_url}/author/john-davenport</uri>
      </author>
    #{entries}
    </feed>
    """
  end

  defp render_entry(base_url, post) do
    url = "#{base_url}/blog/#{post.slug}"
    published = format_date(post.publish_at)
    summary = post.meta_description

    """
      <entry>
        <title>#{escape(post.title || post.slug)}</title>
        <id>#{url}</id>
        <link href="#{url}"/>
        #{if published, do: "<published>#{published}</published>\n    <updated>#{published}</updated>", else: ""}
        #{if summary, do: "<summary>#{escape(summary)}</summary>", else: ""}
      </entry>\
    """
  end

  defp format_date(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_date(_), do: nil

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
