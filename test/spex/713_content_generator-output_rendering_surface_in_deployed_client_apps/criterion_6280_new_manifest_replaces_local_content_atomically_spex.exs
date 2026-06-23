defmodule CodeMySpecSpex.Story713.Criterion6280Spex do
  @moduledoc """
  Story 713 — Content rendering surface in deployed client apps.
  Criterion 6280 — New manifest replaces local content atomically.

  Rule: On hash match the client replaces its local content table in a single
  transaction — wipe existing rows for this project, insert the blob's rows.
  Partial syncs are never visible at the render surface; either the new state
  lands whole or the previous state stays intact.

  Surface:
    * HTTP `POST /api/content/pull` on the client. After a first sync of five
      posts, a second clean sync of four posts leaves exactly those four
      renderable and the dropped fifth returning 404. A sync whose blob fails
      mid-insert leaves the original five intact — no partial state is visible
      at the render surface.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Content.PullClient

  @endpoint CodeMySpecWeb.Endpoint

  setup :set_deploy_key

  @five ~w(a b c d e)
  @four ~w(a b c d)

  # The failing-replace scenario intentionally drives an invalid blob, which
  # makes the atomic persist log :error as it rolls back — an expected,
  # handled condition here, so don't fail the spex on those logs.
  spex "A clean replace lands whole; a failing replace preserves the prior state",
       fail_on_error_logs: false do
    scenario "New manifest replaces local content atomically" do
      given_ "a first sync persisted five posts", context do
        stub_pull(Enum.map(@five, &content_row(&1, "Post #{&1}")), valid: true)
        trigger_pull()

        eventually(fn ->
          assert html_response(get(build_conn(), "/blog/e"), 200) =~ "Post e"
        end)

        {:ok, context}
      end

      when_ "a clean sync of four posts arrives", context do
        stub_pull(Enum.map(@four, &content_row(&1, "Post #{&1}")), valid: true)
        trigger_pull()

        eventually(fn ->
          assert get(build_conn(), "/blog/e").status == 404
        end)

        {:ok, context}
      end

      then_ "exactly the four new posts render and the dropped one is gone", context do
        for slug <- @four do
          assert html_response(get(build_conn(), "/blog/#{slug}"), 200) =~ "Post #{slug}"
        end

        assert get(build_conn(), "/blog/e").status == 404,
               "the replaced-out post must no longer render"

        {:ok, context}
      end
    end

    scenario "A replace that fails mid-insert leaves the original rows intact" do
      given_ "a first sync persisted five posts", context do
        stub_pull(Enum.map(@five, &content_row(&1, "Post #{&1}")), valid: true)
        trigger_pull()

        eventually(fn ->
          assert html_response(get(build_conn(), "/blog/e"), 200) =~ "Post e"
        end)

        {:ok, context}
      end

      when_ "a sync whose blob has an invalid row arrives", context do
        # A row missing the required slug makes the insert fail mid-transaction.
        bad_blob = [content_row("a", "Post a"), Map.delete(content_row("b", "Post b"), "slug")]
        stub_pull(bad_blob, valid: true)
        trigger_pull()
        Process.sleep(200)
        {:ok, context}
      end

      then_ "the original five posts remain renderable", context do
        for slug <- @five do
          assert html_response(get(build_conn(), "/blog/#{slug}"), 200) =~ "Post #{slug}",
                 "a failed transaction must leave the prior five posts intact"
        end

        {:ok, context}
      end
    end
  end

  defp content_row(slug, title) do
    %{
      "slug" => slug,
      "title" => title,
      "content_type" => "blog",
      "processed_content" => "# #{title}\n\nBody.",
      "protected" => false,
      "publish_at" => "2020-01-01T00:00:00Z",
      "expires_at" => nil,
      "tags" => []
    }
  end

  defp trigger_pull do
    build_conn()
    |> put_req_header("authorization", "Bearer k-abc123")
    |> put_req_header("content-type", "application/json")
    |> post("/api/content/pull", %{"manifest_url" => "https://content.foo.com/manifest.json"})
  end

  defp stub_pull(blob_rows, _opts) do
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
