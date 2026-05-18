defmodule CodeMySpecWeb.SitemapControllerTest do
  use CodeMySpecTest.ConnCase, async: false

  import CodeMySpec.ContentFixtures

  describe "GET /sitemap.xml" do
    test "emits per-post publish_at as <lastmod> instead of a uniform timestamp", %{conn: conn} do
      may_3 = ~U[2026-05-03 00:00:00Z]
      mar_31 = ~U[2026-03-31 00:00:00Z]

      blog_post_fixture(nil, nil, %{slug: "bdd-attention-thesis", publish_at: may_3})
      blog_post_fixture(nil, nil, %{slug: "the-harness-layer", publish_at: mar_31})

      body =
        conn
        |> get(~p"/sitemap.xml")
        |> response(200)

      assert body =~ "<loc>" <> CodeMySpecWeb.Endpoint.url() <> "/blog/bdd-attention-thesis</loc>"
      assert body =~ "<lastmod>2026-05-03T00:00:00Z</lastmod>"
      assert body =~ "<loc>" <> CodeMySpecWeb.Endpoint.url() <> "/blog/the-harness-layer</loc>"
      assert body =~ "<lastmod>2026-03-31T00:00:00Z</lastmod>"
    end

    test "excludes /pages/{slug} entries that the legacy redirect plug intercepts", %{conn: conn} do
      # A page_fixture with a slug that matches a legacy_redirect target should NOT
      # appear at /pages/{slug} in the sitemap — Google would just hit a 301.
      page_fixture(nil, nil, %{
        slug: "cli-agents-compared-2026",
        publish_at: ~U[2026-03-17 00:00:00Z]
      })

      body =
        conn
        |> get(~p"/sitemap.xml")
        |> response(200)

      refute body =~ "/pages/cli-agents-compared-2026"
    end
  end
end
