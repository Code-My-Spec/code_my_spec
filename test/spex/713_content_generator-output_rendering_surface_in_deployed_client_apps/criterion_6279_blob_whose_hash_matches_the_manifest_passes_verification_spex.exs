defmodule CodeMySpecSpex.Story713.Criterion6279Spex do
  @moduledoc """
  Story 713 — Content rendering surface in deployed client apps.
  Criterion 6279 — Blob whose hash matches the manifest passes verification.

  Rule: The client fetches the content blob from `content_blob_url`, computes
  `sha256(blob_bytes)`, and compares it to `manifest.content_blob_hash`.
  Mismatch rejects the sync entirely — no partial writes on integrity failure;
  existing content stays untouched until a clean sync succeeds.

  Surface:
    * HTTP `POST /api/content/pull` on the client. A blob whose sha256 matches
      the manifest hash verifies and persists — its content renders at
      `/blog/:slug`. A subsequent pull whose blob hash does NOT match the
      manifest is rejected: the previously-synced content still renders and
      the mismatched content never appears.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :set_deploy_key

  spex "Hash match persists; hash mismatch leaves existing content untouched" do
    scenario "Blob whose hash matches the manifest passes verification" do
      given_ "a first clean sync persisted the alpha post", context do
        Fixtures.stub_content_pull([content_row("alpha", "Alpha Post")])
        trigger_pull()

        eventually(fn ->
          assert html_response(get(build_conn(), "/blog/alpha"), 200) =~ "Alpha Post"
        end)

        {:ok, context}
      end

      when_ "a pull arrives whose blob hash does not match the manifest", context do
        Fixtures.stub_content_pull([content_row("beta", "Beta Post")], hash: :mismatched)
        trigger_pull()
        {:ok, context}
      end

      then_ "the mismatch is rejected and existing content survives", context do
        assert html_response(get(build_conn(), "/blog/alpha"), 200) =~ "Alpha Post",
               "existing content must remain untouched on integrity failure"

        assert get(build_conn(), "/blog/beta").status == 404,
               "content from a hash-mismatched blob must never be persisted"

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

  defp set_deploy_key(_context) do
    previous = Application.get_env(:code_my_spec, :deploy_key)
    Application.put_env(:code_my_spec, :deploy_key, "k-abc123")
    on_exit(fn -> Application.put_env(:code_my_spec, :deploy_key, previous) end)
    :ok
  end
end
