defmodule CodeMySpecSpex.Story713.Criterion6281Spex do
  @moduledoc """
  Story 713 — Content rendering surface in deployed client apps.
  Criterion 6281 — Future-publish and expired slugs return 404 without
  re-pulling.

  Rule: Render-time queries filter by `publish_at <= now()` AND
  (`expires_at IS NULL OR expires_at > now()`). Out-of-window slugs — unknown,
  not-yet-published, expired — all return 404 (not redirect, not a custom
  error page). The manifest stays static; there is no scheduler daemon.
  Schedule transitions are observed at render time, not via background
  re-pulls.

  Surface:
    * HTTP `GET /blog/:slug` on the client. With three posts synced — alpha
      (published, no expiry), beta (future publish), gamma (expired) — alpha
      renders 200 while beta, gamma, and an unknown slug return 404. No
      manifest re-pull happens between render requests.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :set_deploy_key

  spex "Schedule windows are enforced at render time, with no background re-pull" do
    scenario "Future-publish and expired slugs return 404 without re-pulling" do
      given_ "three posts with different schedule windows are synced", context do
        now = DateTime.utc_now()

        yesterday =
          DateTime.add(now, -1, :day) |> DateTime.truncate(:second) |> DateTime.to_iso8601()

        tomorrow =
          DateTime.add(now, 1, :day) |> DateTime.truncate(:second) |> DateTime.to_iso8601()

        two_days_ago =
          DateTime.add(now, -2, :day) |> DateTime.truncate(:second) |> DateTime.to_iso8601()

        rows = [
          row("alpha", publish_at: yesterday, expires_at: nil),
          row("beta", publish_at: tomorrow, expires_at: nil),
          # expired: published two days ago, expired yesterday (expires > publish, both past)
          row("gamma", publish_at: two_days_ago, expires_at: yesterday)
        ]

        Fixtures.stub_content_pull(rows)
        trigger_pull()

        eventually(fn ->
          assert html_response(get(build_conn(), "/blog/alpha"), 200) =~ "alpha"
        end)

        # Drain any fetch messages from the seed pull so the next assertion
        # only sees fetches that happen during rendering.
        flush()

        {:ok, context}
      end

      when_ "a visitor requests each slug", context do
        statuses = %{
          "alpha" => get(build_conn(), "/blog/alpha").status,
          "beta" => get(build_conn(), "/blog/beta").status,
          "gamma" => get(build_conn(), "/blog/gamma").status,
          "unknown" => get(build_conn(), "/blog/unknown").status
        }

        {:ok, Map.put(context, :statuses, statuses)}
      end

      then_ "in-window renders 200; out-of-window and unknown return 404; no re-pull", context do
        assert context.statuses["alpha"] == 200
        assert context.statuses["beta"] == 404, "a not-yet-published slug must 404"
        assert context.statuses["gamma"] == 404, "an expired slug must 404"
        assert context.statuses["unknown"] == 404, "an unknown slug must 404"

        refute_received {:pull_fetch, _url},
                        "rendering must not trigger a background manifest re-pull"

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
      "tags" => []
    }
  end

  defp trigger_pull do
    build_conn()
    |> put_req_header("authorization", "Bearer k-abc123")
    |> put_req_header("content-type", "application/json")
    |> post("/api/content/pull", %{"manifest_url" => "https://content.foo.com/manifest.json"})
  end

  defp set_deploy_key(_context) do
    previous = Application.get_env(:code_my_spec, :deploy_key)
    Application.put_env(:code_my_spec, :deploy_key, "k-abc123")
    on_exit(fn -> Application.put_env(:code_my_spec, :deploy_key, previous) end)
    :ok
  end

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end
end
