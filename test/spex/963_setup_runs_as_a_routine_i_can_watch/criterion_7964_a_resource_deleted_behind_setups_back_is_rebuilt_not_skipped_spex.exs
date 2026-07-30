defmodule CodeMySpecSpex.Story963.Criterion7964Spex do
  @moduledoc """
  Story 963 — Setup runs as a routine I can watch
  Criterion 7964 — A resource deleted behind setup's back is rebuilt, not skipped.

  A step that succeeded once is not trusted forever. If Sam deletes the
  server in the Hetzner console, the next run finds it missing and runs
  the server step again rather than skipping on the strength of the old
  result. This is what makes the status page's state trustworthy instead
  of merely remembered.

  Two cassettes: the first provisions the server, the second answers
  "that server does not exist" when setup re-checks.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @create_cassette "hetzner_server_create_ok"
  @gone_cassette "hetzner_server_missing_then_recreated"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A resource deleted behind setup's back is rebuilt, not skipped" do
    scenario "the server step runs again when the server is gone" do
      given_ "the server step previously succeeded", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        ReqCassette.with_cassette(@create_cassette, [mode: :replay], fn ->
          view
          |> element("[data-test='setup-step'][data-step='server'] [data-test='run-step']")
          |> render_click()
        end)

        assert render(view) =~ ~r/data-step="server"[^>]*data-state="done"/,
               "expected the server step to be done before the resource is deleted"

        {:ok, Map.put(context, :view, view)}
      end

      when_ "Sam has deleted that server and setup runs again", context do
        # The cassette answers the existence check with "not found", which
        # is how setup learns the resource is gone.
        ReqCassette.with_cassette(@gone_cassette, [mode: :replay], fn ->
          context.view |> element("[data-test='start-setup']") |> render_click()
        end)

        {:ok, Map.put(context, :html, render(context.view))}
      end

      then_ "setup runs the server step again rather than skipping it", context do
        assert context.html =~ ~r/data-step="server"[^>]*data-state="(running|done)"/,
               "expected the server step to be re-run once its resource was found missing"

        refute context.html =~ ~r/data-step="server"[^>]*data-state="skipped"/,
               "expected setup not to skip the step on the strength of the old result"

        {:ok, context}
      end
    end
  end
end
