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
  alias CodeMySpec.Content.S3Client
  alias CodeMySpec.Content.TriggerClient

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

        assert html =~ "broken",
               "the publish error must name the failing file"

        assert has_element?(context.view, "[data-test='publish-error']"),
               "publish must surface a blocking error, not proceed"

        refute_received {:s3_put, _target},
                        "no manifest or blob may be written to S3 when parse errors remain"

        refute_received {:trigger_post, _url, _body},
                        "no pull trigger may be POSTed to the client when publish aborts"

        {:ok, context}
      end
    end
  end

  defp stub_outbound(_context) do
    Req.Test.set_req_test_to_shared(%{})
    test_pid = self()

    for {mod, msg} <- [{S3Client, :s3_put}, {TriggerClient, :trigger_post}] do
      previous = Application.get_env(:code_my_spec, mod, [])
      Application.put_env(:code_my_spec, mod, plug: {Req.Test, mod})
      on_exit(fn -> Application.put_env(:code_my_spec, mod, previous) end)

      Req.Test.stub(mod, fn conn ->
        case msg do
          :s3_put ->
            send(test_pid, {:s3_put, conn.host <> conn.request_path})

          :trigger_post ->
            {:ok, body, _} = Plug.Conn.read_body(conn)
            send(test_pid, {:trigger_post, conn.request_path, body})
        end

        Plug.Conn.send_resp(conn, 200, "")
      end)
    end

    :ok
  end
end
