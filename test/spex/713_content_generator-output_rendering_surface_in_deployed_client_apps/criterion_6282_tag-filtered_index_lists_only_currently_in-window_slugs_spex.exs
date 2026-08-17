defmodule CodeMySpecSpex.Story713.Criterion6282Spex do
  @moduledoc """
  Story 713 — Content rendering surface in deployed client apps.
  Criterion 6282 — Tag-filtered index lists only currently in-window slugs.

  Rule: Dead-view controllers handle canonical slug routes (`/blog/:slug`,
  `/pages/:slug`, `/landing/:slug`, `/documentation/:slug`) and index/tag-
  filtered routes (`/blog`, `/blog/tag/:tag`, and equivalents for other
  content_types). All routes apply the render-time schedule filter;
  tag-filtered index views only list slugs that are currently in-window.

  Surface:
    * HTTP `GET /blog/tag/:tag` on the client. With four `ai`-tagged posts —
      p1, p2 in-window, p3 expired, p4 future — the tag index lists exactly
      p1 and p2; p3 and p4 are absent, and visiting them directly returns 404.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Content.PullClient

  @endpoint CodeMySpecWeb.Endpoint

  setup :set_deploy_key

  spex "A tag index lists only in-window posts for that tag" do
    scenario "Tag-filtered index lists only currently in-window slugs" do
      given_ "four ai-tagged posts with mixed schedule windows are synced", context do
        now = DateTime.utc_now()

        yesterday =
          DateTime.add(now, -1, :day) |> DateTime.truncate(:second) |> DateTime.to_iso8601()

        tomorrow =
          DateTime.add(now, 1, :day) |> DateTime.truncate(:second) |> DateTime.to_iso8601()

        two_days_ago =
          DateTime.add(now, -2, :day) |> DateTime.truncate(:second) |> DateTime.to_iso8601()

        rows = [
          row("p1", publish_at: yesterday, expires_at: nil),
          row("p2", publish_at: yesterday, expires_at: nil),
          # expired: published two days ago, expired yesterday (expires > publish, both past)
          row("p3", publish_at: two_days_ago, expires_at: yesterday),
          row("p4", publish_at: tomorrow, expires_at: nil)
        ]

        stub_pull(rows)
        trigger_pull()

        # Every in-window post, not just the first. The pull is asynchronous
        # and lands a post at a time, so waiting on `p1` alone let the `when_`
        # read the tag index while `p2` was still arriving — an index missing
        # `p2` then failed an assertion about filtering, which is not what was
        # wrong.
        #
        # This is what the harness kept catching and an isolated run did not:
        # the window is only as wide as the machine is busy, and the sweep runs
        # beside the analyzer. Giving `eventually/2` a longer deadline, which
        # is where I looked first, does not help a wait that is watching the
        # wrong thing.
        for slug <- ~w(p1 p2) do
          eventually(fn ->
            assert html_response(get(build_conn(), "/blog/#{slug}"), 200) =~ slug
          end)
        end

        {:ok, context}
      end

      when_ "a visitor opens the ai tag index", context do
        conn = get(build_conn(), "/blog/tag/ai")
        {:ok, Map.put(context, :index_html, html_response(conn, 200))}
      end

      then_ "only the in-window posts are listed and out-of-window ones 404", context do
        assert context.index_html =~ "p1"
        assert context.index_html =~ "p2"

        refute context.index_html =~ "p3", "an expired post must not appear in the tag index"
        refute context.index_html =~ "p4", "a future post must not appear in the tag index"

        assert get(build_conn(), "/blog/p3").status == 404
        assert get(build_conn(), "/blog/p4").status == 404

        {:ok, context}
      end
    end
  end

  defp row(slug, opts) do
    %{
      "slug" => slug,
      "title" => slug,
      "content_type" => "blog",
      "processed_content" => "# #{slug}\n\nBody.",
      "protected" => false,
      "publish_at" => Keyword.fetch!(opts, :publish_at),
      "expires_at" => Keyword.fetch!(opts, :expires_at),
      "tags" => ["ai"]
    }
  end

  defp trigger_pull do
    build_conn()
    |> put_req_header("authorization", "Bearer k-abc123")
    |> put_req_header("content-type", "application/json")
    |> post("/api/content/pull", %{"manifest_url" => "https://content.foo.com/manifest.json"})
  end

  defp stub_pull(blob_rows) do
    Req.Test.set_req_test_to_shared(%{})
    Application.put_env(:code_my_spec, PullClient, plug: {Req.Test, PullClient})
    on_exit(fn -> Application.delete_env(:code_my_spec, PullClient) end)

    blob_json = Jason.encode!(blob_rows)
    hash = "sha256:" <> (:crypto.hash(:sha256, blob_json) |> Base.encode16(case: :lower))

    manifest = %{
      "version" => "1.0",
      "generated_at" => "2026-05-15T12:00:00Z",
      "content_blob_url" => "https://content.foo.com/content.json",
      "content_blob_hash" => hash,
      "counts" => %{"blog" => length(blob_rows)}
    }

    Req.Test.stub(PullClient, fn conn ->
      body =
        case conn.request_path do
          "/manifest.json" -> Jason.encode!(manifest)
          "/content.json" -> blob_json
          _ -> "{}"
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, body)
    end)

    :ok
  end

  defp set_deploy_key(_context) do
    previous = Application.get_env(:code_my_spec, :deploy_key)
    Application.put_env(:code_my_spec, :deploy_key, "k-abc123")
    on_exit(fn -> Application.put_env(:code_my_spec, :deploy_key, previous) end)
    :ok
  end
end
