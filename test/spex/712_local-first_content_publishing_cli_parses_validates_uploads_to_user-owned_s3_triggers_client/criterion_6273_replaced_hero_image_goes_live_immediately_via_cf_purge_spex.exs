defmodule CodeMySpecSpex.Story712.Criterion6273Spex do
  @moduledoc """
  Story 712 — Local-first content publishing.
  Criterion 6273 — Replaced hero image goes live immediately via CF purge.

  Rule: Replaced images (same filename, different bytes) trigger a Cloudflare
  cache purge for those specific paths so the new bytes go live without
  waiting for the edge TTL. The CLI carries the Cloudflare API token; the
  SaaS never sees it.

  Surface:
    * Local-web admin LiveView at `/admin/content`. After an initial sync
      uploads `hero-foo.webp`, the operator changes the file's bytes (same
      filename) and re-syncs. The new bytes upload to S3 and the local
      process POSTs a Cloudflare cache purge for
      `https://images.foo.com/hero-foo.webp`. Both outbound calls are
      captured to prove the purge fires only for the replaced path.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpec.Content.S3Client
  alias CodeMySpec.Content.CloudflareClient

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :stub_s3
  setup :stub_cloudflare

  @source "codemyspec-content"

  spex "A replaced image is purged from the Cloudflare edge on re-sync" do
    scenario "Replaced hero image goes live immediately via CF purge" do
      given_ "an already-synced hero image and Cloudflare configured", context do
        env = context.environment

        :ok = Environments.write_file(env, "#{@source}/images/hero-foo.webp", "original-bytes")

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

        # First sync: the image is uploaded and now lives at the edge.
        view |> element("[data-test='sync-button']") |> render_click()
        # Drain any messages from the first sync — we only assert the second.
        flush_messages()

        {:ok, Map.put(context, :view, view)}
      end

      when_ "Sam replaces the image bytes and re-syncs", context do
        :ok =
          Environments.write_file(
            context.environment,
            "#{@source}/images/hero-foo.webp",
            "new-bytes"
          )

        context.view |> element("[data-test='sync-button']") |> render_click()
        {:ok, context}
      end

      then_ "the new bytes upload and a CF purge fires for that exact path", context do
        assert_received {:s3_put, target}, "expected the replaced bytes uploaded to S3"

        assert target =~ "images.foo.com" and target =~ "hero-foo.webp",
               "expected hero-foo.webp re-uploaded to the images.foo.com bucket; got #{inspect(target)}"

        assert_received {:cf_purge, urls},
                        "expected a Cloudflare cache purge to be POSTed"

        assert "https://images.foo.com/hero-foo.webp" in urls,
               "the purge must target the replaced image's exact CDN URL"

        {:ok, context}
      end
    end
  end

  defp stub_s3(_context) do
    Req.Test.set_req_test_to_shared(%{})
    previous = Application.get_env(:code_my_spec, S3Client, [])
    Application.put_env(:code_my_spec, S3Client, plug: {Req.Test, S3Client})
    on_exit(fn -> Application.put_env(:code_my_spec, S3Client, previous) end)

    test_pid = self()

    Req.Test.stub(S3Client, fn conn ->
      send(test_pid, {:s3_put, conn.host <> conn.request_path})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    :ok
  end

  defp stub_cloudflare(_context) do
    previous = Application.get_env(:code_my_spec, CloudflareClient, [])
    Application.put_env(:code_my_spec, CloudflareClient, plug: {Req.Test, CloudflareClient})
    on_exit(fn -> Application.put_env(:code_my_spec, CloudflareClient, previous) end)

    test_pid = self()

    Req.Test.stub(CloudflareClient, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      urls = body |> Jason.decode!() |> Map.get("files", [])
      send(test_pid, {:cf_purge, urls})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"success":true}))
    end)

    :ok
  end

  defp flush_messages do
    receive do
      _ -> flush_messages()
    after
      0 -> :ok
    end
  end
end
