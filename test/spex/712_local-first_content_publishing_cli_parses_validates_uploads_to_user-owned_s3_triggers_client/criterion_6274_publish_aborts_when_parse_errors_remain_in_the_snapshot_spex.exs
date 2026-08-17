defmodule CodeMySpecSpex.Story712.Criterion6274Spex do
  @moduledoc """
  Story 712 — Local-first content publishing.
  Criterion 6274 — Publish aborts when parse errors remain in the snapshot.

  Rule: Publish refuses to proceed if any `parse_status: :error` row exists in
  the local snapshot OR any image upload failed during the latest sync. The
  operator must reconcile (re-sync clean, fix the offending files) before
  publish writes anything to S3 or triggers the client.

  Surface:
    * Local-web admin LiveView at `/admin/content`. With a snapshot holding
      one error row, clicking "Publish" surfaces an error naming the failing
      file, writes no manifest or blob to S3, and POSTs no pull trigger to
      the client. The S3 and trigger clients are stubbed so the absence of
      any outbound call can be asserted.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :stub_outbound

  @source "codemyspec-content"

  spex "Publish refuses to run while the snapshot still has parse errors" do
    scenario "Publish aborts when parse errors remain in the snapshot" do
      given_ "a synced snapshot with one parse-error row", context do
        env = context.environment

        :ok =
          Environments.write_file(env, "#{@source}/blog/good.md", """
          ---
          title: Good
          slug: good
          content_type: blog
          ---
          Body.
          """)

        :ok =
          Environments.write_file(env, "#{@source}/blog/broken.md", """
          ---
          : : not valid yaml
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
        html = context.view |> element("[data-test='publish-button']") |> render_click()
        {:ok, Map.put(context, :html, html)}
      end

      then_ "publish errors naming the file and writes/triggers nothing", context do
        html = render(context.view)

        # Read inside the error alert. `html =~ "broken"` was the whole page,
        # which lists `broken.md` in the content table whether or not the error
        # names it — so the criterion's own subject, that the error names the
        # failing file, was the part not being checked.
        assert has_element?(context.view, "[data-test='publish-error']", "broken"),
               "publish must surface a blocking error naming the failing file, got:\n#{html}"

        refute_received {:s3_put, _target, _body},
                        "no manifest or blob may be written to S3 when parse errors remain"

        refute_received {:trigger, _request},
                        "no pull trigger may be POSTed to the client when publish aborts"

        {:ok, context}
      end
    end
  end

  # Both stubs live in the bridge: a spex may not call `send/2`, and that holds
  # for its helpers too.
  defp stub_outbound(_context), do: Fixtures.stub_publishing_outbound(self())
end
