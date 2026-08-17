defmodule CodeMySpecSpex.Story712.Criterion6276Spex do
  @moduledoc """
  Story 712 — Local-first content publishing.
  Criterion 6276 — Client gets pull trigger and fetches the manifest from S3.

  Rule: After S3 acknowledges both writes, publish HTTP-POSTs to
  `<client_api_url>/api/content/pull` with `Authorization: Bearer <deploy_key>`
  and the manifest URL in the body. The client pulls the manifest, verifies
  the hash, pulls the blob, and persists. Publish marks complete on a 200 from
  the client; on non-200, publish surfaces the failure but leaves the S3
  manifest in place so a re-trigger is cheap.

  Surface:
    * Local-web admin LiveView at `/admin/content`. With the manifest + blob
      written and a configured `client_api_url` + `deploy_key`, publish POSTs
      to `https://app.foo.com/api/content/pull` carrying
      `Authorization: Bearer <deploy_key>` and the manifest URL. On the
      client's 200, publish marks complete and surfaces a sync id in the
      admin surface. The trigger client is stubbed to assert the URL, header,
      and body.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :stub_s3
  setup :stub_trigger

  @source "codemyspec-content"

  spex "Publish triggers the client to pull, and completes on the client's 200" do
    scenario "Client gets pull trigger and fetches the manifest from S3" do
      given_ "a clean snapshot with the client api url and deploy key set", context do
        :ok =
          Environments.write_file(context.environment, "#{@source}/blog/foo.md", """
          ---
          title: Foo
          slug: foo
          content_type: blog
          ---
          Body.
          """)

        {:ok, view, _html} = live(context.conn, "/app/projects/#{context.project.id}/content")

        view
        |> form("[data-test='content-settings-form']",
          settings: %{
            content_bucket: "content.foo.com",
            client_api_url: "https://app.foo.com",
            deploy_key: "k-abc123"
          }
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

      then_ "the client is triggered with bearer auth and the manifest url", context do
        assert_received {:trigger, request},
                        "expected a POST to the client's pull endpoint"

        assert request.url =~ "https://app.foo.com/api/content/pull",
               "the trigger must hit <client_api_url>/api/content/pull"

        assert request.auth == "Bearer k-abc123",
               "the trigger must carry Authorization: Bearer <deploy_key>"

        assert request.body["manifest_url"] =~ "content.foo.com",
               "the trigger body must carry the manifest URL"

        assert request.body["manifest_url"] =~ "manifest.json"

        assert has_element?(context.view, "[data-test='publish-sync-id']"),
               "on the client's 200, publish must mark complete with a surfaced sync id"

        {:ok, context}
      end
    end
  end

  defp stub_s3(_context), do: Fixtures.stub_s3_puts(self())

  defp stub_trigger(_context), do: Fixtures.stub_trigger_posts(self())
end
