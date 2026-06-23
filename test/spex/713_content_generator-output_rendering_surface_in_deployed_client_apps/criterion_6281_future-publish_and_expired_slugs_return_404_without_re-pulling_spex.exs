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

  alias CodeMySpec.Content.PullClient

  @endpoint CodeMySpecWeb.Endpoint

  setup :set_deploy_key

  spex "Schedule windows are enforced at render time, with no background re-pull" do
    scenario "Future-publish and expired slugs return 404 without re-pulling" do
      given_ "three posts with different schedule windows are synced", context do
        now = DateTime.utc_now()
        yesterday = DateTime.add(now, -1, :day) |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        tomorrow = DateTime.add(now, 1, :day) |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        two_days_ago = DateTime.add(now, -2, :day) |> DateTime.truncate(:second) |> DateTime.to_iso8601()

        rows = [
          row("alpha", publish_at: yesterday, expires_at: nil),
          row("beta", publish_at: tomorrow, expires_at: nil),
          # expired: published two days ago, expired yesterday (expires > publish, both past)
          row("gamma", publish_at: two_days_ago, expires_at: yesterday)
        ]

        stub_pull(rows)
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

    test_pid = self()

    Req.Test.stub(PullClient, fn conn ->
      url = "#{conn.scheme}://#{conn.host}#{conn.request_path}"
      send(test_pid, {:pull_fetch, url})

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

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end

  defp eventually(fun, retries \\ 40)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, n) do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(25)
      eventually(fun, n - 1)
  end
end
