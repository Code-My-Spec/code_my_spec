defmodule CodeMySpecSpex.Story712.Criterion6271Spex do
  @moduledoc """
  Story 712 — Local-first content publishing.
  Criterion 6271 — Images upload to the user's S3 image bucket on sync.

  Rule: Images in the content directory (`content/images/` and any markdown
  `![](...)` refs) upload to the project's per-project S3 image bucket during
  sync. The CLI carries the AWS credentials directly; they never traverse the
  CodeMySpec SaaS. Sync result includes per-image success/failure counts.

  Surface:
    * Local-web admin LiveView at `/admin/content`. The user's own AWS
      credentials are carried by the local process (here replayed via
      `Req.Test`). On sync, a referenced image uploads to
      `s3://images.foo.com/hero-foo.webp` and the summary reports
      `1 image synced, 0 failed`. The outbound request is captured to prove
      it targets the user's bucket directly, not via the SaaS.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :stub_s3

  @source "codemyspec-content"

  spex "Images upload to the user's own S3 image bucket on sync" do
    scenario "Images upload to the user's S3 image bucket on sync" do
      given_ "a post referencing an image and the project's image bucket configured", context do
        env = context.environment

        :ok =
          Environments.write_file(env, "#{@source}/images/hero-foo.webp", "fake-webp-bytes")

        :ok =
          Environments.write_file(env, "#{@source}/blog/foo.md", """
          ---
          title: Foo
          slug: foo
          content_type: blog
          ---
          ![Hero](./images/hero-foo.webp)
          """)

        {:ok, view, _html} = live(context.conn, "/app/projects/#{context.project.id}/content")

        view
        |> form("[data-test='content-settings-form']",
          settings: %{image_bucket: "images.foo.com", images_host: "https://images.foo.com"}
        )
        |> render_submit()

        view
        |> form("[data-test='content-source-form']", source: %{path: @source})
        |> render_submit()

        {:ok, Map.put(context, :view, view)}
      end

      when_ "Sam runs a content sync", context do
        context.view |> element("[data-test='sync-button']") |> render_click()
        {:ok, context}
      end

      then_ "the image uploads to the user's bucket and the summary counts it", context do
        assert_received {:s3_put, target, _body}, "expected an S3 upload during sync"

        assert target =~ "images.foo.com" and target =~ "hero-foo.webp",
               "expected hero-foo.webp uploaded to the images.foo.com bucket; got #{inspect(target)}"

        assert render(context.view) =~ "1 image synced, 0 failed",
               "expected the sync summary to report 1 image synced, 0 failed"

        {:ok, context}
      end
    end
  end

  defp stub_s3(_context), do: Fixtures.stub_s3_puts(self())
end
