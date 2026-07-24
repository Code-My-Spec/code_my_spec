defmodule CodeMySpecWeb.FeedControllerTest do
  use CodeMySpecTest.ConnCase, async: false

  import CodeMySpec.ContentFixtures

  describe "GET /blog/feed.xml" do
    test "serves an Atom feed with published posts newest-first", %{conn: conn} do
      blog_post_fixture(nil, nil, %{
        slug: "older-post",
        title: "Older Post",
        publish_at: ~U[2026-03-31 00:00:00Z]
      })

      blog_post_fixture(nil, nil, %{
        slug: "newer-post",
        title: "Newer & Better Post",
        publish_at: ~U[2026-05-03 00:00:00Z]
      })

      conn = get(conn, ~p"/blog/feed.xml")
      body = response(conn, 200)

      assert response_content_type(conn, :atom) =~ "application/atom+xml"
      assert body =~ ~s(<feed xmlns="http://www.w3.org/2005/Atom">)
      # Feed-level updated mirrors the newest entry, not request time.
      assert body =~ "<updated>2026-05-03T00:00:00Z</updated>"
      # Titles are XML-escaped.
      assert body =~ "Newer &amp; Better Post"

      newer_idx = :binary.match(body, "/blog/newer-post") |> elem(0)
      older_idx = :binary.match(body, "/blog/older-post") |> elem(0)
      assert newer_idx < older_idx
    end

    test "serves a valid empty feed when nothing is published", %{conn: conn} do
      body =
        conn
        |> get(~p"/blog/feed.xml")
        |> response(200)

      assert body =~ "<title>CodeMySpec Blog</title>"
      refute body =~ "<entry>"
    end
  end
end
