defmodule CodeMySpecSpex.Story712.Criterion6272Spex do
  @moduledoc """
  Story 712 — Local-first content publishing.
  Criterion 6272 — Markdown image URLs rewrite to CDN host before
  persistence.

  Rule: Markdown image refs are rewritten from source-directory-relative
  paths to the user's `$images_host` CDN URL before persistence to the local
  snapshot. The stored content carries only CDN URLs — clients pulling the
  manifest never see repo paths.

  Surface:
    * Local-web admin LiveView at `/admin/content`. After sync, the rendered
      snapshot row for `foo` exposes processed content where
      `![Hero](./images/hero-foo.webp)` has become
      `![Hero](https://images.foo.com/hero-foo.webp)`, with no
      source-relative path remaining.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :stub_s3

  @source "codemyspec-content"

  spex "Source-relative image paths become CDN URLs before they are stored" do
    scenario "Markdown image URLs rewrite to CDN host before persistence" do
      given_ "a post with a source-relative image ref and a configured CDN host", context do
        env = context.environment

        :ok = Environments.write_file(env, "#{@source}/images/hero-foo.webp", "bytes")

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

      then_ "the stored processed content carries the CDN URL, not the repo path", context do
        # Full content lives on the detail page, not the index table.
        {:ok, show_view, _html} =
          context.view
          |> element("[data-test='content-row-link-foo']")
          |> render_click()
          |> follow_redirect(context.conn)

        processed =
          show_view
          |> element("[data-test='processed-content-foo']")
          |> render()

        assert processed =~ "https://images.foo.com/hero-foo.webp",
               "expected the image ref rewritten to the CDN host in the rendered content"

        refute processed =~ "./images/hero-foo.webp",
               "no source-directory-relative path may remain in stored content"

        {:ok, context}
      end
    end
  end

  defp stub_s3(_context), do: Fixtures.stub_s3_puts(self())
end
