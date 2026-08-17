defmodule CodeMySpecSpex.Story712.Criterion6275Spex do
  @moduledoc """
  Story 712 — Local-first content publishing.
  Criterion 6275 — Publish writes manifest + blob to user's content bucket.

  Rule: Publish writes a manifest JSON and a content blob JSON to the
  project's per-project content S3 bucket. Only rows with
  `parse_status: :success` enter the blob. Manifest fields: `version`,
  `generated_at` (ISO8601), `content_blob_url`, `content_blob_hash` (sha256 of
  the blob), `counts` (per content_type). The hash lets the client verify
  integrity end-to-end.

  Surface:
    * Local-web admin LiveView at `/admin/content`. With a clean snapshot of
      three blog rows and one page row, clicking "Publish" writes
      `content.json` (4 rows) and `manifest.json` to `content.foo.com`. The
      manifest carries version, ISO8601 `generated_at`, the blob URL, a
      sha256 matching the blob bytes, and per-type counts. Both writes are
      captured to assert their bucket, keys, and manifest contents.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :stub_s3

  @source "codemyspec-content"

  spex "Publish writes the content blob and an integrity manifest to S3" do
    scenario "Publish writes manifest + blob to user's content bucket" do
      given_ "a clean snapshot of three blog rows and one page row", context do
        env = context.environment

        for slug <- ~w(one two three) do
          :ok =
            Environments.write_file(env, "#{@source}/blog/#{slug}.md", """
            ---
            title: #{slug}
            slug: #{slug}
            content_type: blog
            ---
            Body.
            """)
        end

        :ok =
          Environments.write_file(env, "#{@source}/pages/about.md", """
          ---
          title: About
          slug: about
          content_type: page
          ---
          About body.
          """)

        {:ok, view, _html} = live(context.conn, "/app/projects/#{context.project.id}/content")

        view
        |> form("[data-test='content-settings-form']",
          settings: %{content_bucket: "content.foo.com"}
        )
        |> render_submit()

        view
        |> form("[data-test='content-source-form']", source: %{path: @source})
        |> render_submit()

        view |> element("[data-test='sync-button']") |> render_click()

        {:ok, Map.put(context, :view, view)}
      end

      when_ "Sam clicks Publish", context do
        context.view |> element("[data-test='publish-button']") |> render_click()
        {:ok, context}
      end

      then_ "blob and manifest land in the content bucket with a matching hash", context do
        puts = drain_puts([])
        blob = find_put(puts, "content.foo.com", "content.json")
        manifest_bytes = find_put(puts, "content.foo.com", "manifest.json")

        assert blob, "expected content.json written to s3://content.foo.com/content.json"

        assert manifest_bytes,
               "expected manifest.json written to s3://content.foo.com/manifest.json"

        manifest = Jason.decode!(manifest_bytes)

        assert manifest["version"] == "1.0"
        assert {:ok, _, _} = DateTime.from_iso8601(manifest["generated_at"])
        assert manifest["content_blob_url"] =~ "content.foo.com"
        assert manifest["content_blob_url"] =~ "content.json"

        assert manifest["content_blob_hash"] == "sha256:" <> sha256(blob),
               "the manifest hash must be the sha256 of the blob bytes (wire format: sha256:<hex>)"

        assert manifest["counts"] == %{"blog" => 3, "page" => 1}

        assert length(Jason.decode!(blob)) == 4,
               "only the four parse_status: success rows belong in the blob"

        {:ok, context}
      end
    end
  end

  defp drain_puts(acc) do
    receive do
      {:s3_put, target, body} -> drain_puts([{target, body} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp find_put(puts, bucket, key) do
    puts
    |> Enum.filter(&addressed_to?(&1, bucket, key))
    |> Enum.map(fn {_target, body} -> body end)
    |> List.first()
  end

  defp addressed_to?({target, _body}, bucket, key) do
    String.contains?(target, bucket) and String.contains?(target, key)
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp stub_s3(_context), do: Fixtures.stub_s3_puts(self())
end
