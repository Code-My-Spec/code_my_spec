defmodule CodeMySpecSpex.Story963.Criterion7963Spex do
  @moduledoc """
  Story 963 — Setup runs as a routine I can watch
  Criterion 7963 — A re-run picks up where it stopped.

  After fixing whatever broke, running setup again resumes at the failed
  step. Steps that already succeeded stay succeeded and are not
  re-executed — re-running from the top would re-provision servers and
  re-charge for domains.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @first_run_cassette "setup_run_stops_at_email"
  @resume_cassette "setup_resume_from_email_ok"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A re-run picks up where it stopped" do
    scenario "the earlier steps stay done and the run resumes at the email step" do
      given_ "setup stopped at the email step with earlier steps succeeded", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        ReqCassette.with_cassette(@first_run_cassette, [mode: :replay], fn ->
          view |> element("[data-test='start-setup']") |> render_click()
        end)

        html = render(view)

        assert html =~ ~r/data-step="email"[^>]*data-state="errored"/,
               "expected the first run to stop at the email step"

        {:ok, context |> Map.put(:view, view) |> Map.put(:first_run_html, html)}
      end

      when_ "Sam fixes the credential and runs setup again", context do
        ReqCassette.with_cassette(@resume_cassette, [mode: :replay], fn ->
          context.view |> element("[data-test='start-setup']") |> render_click()
        end)

        {:ok, Map.put(context, :html, render(context.view))}
      end

      then_ "the steps that already succeeded stay succeeded", context do
        done_before = done_steps(context.first_run_html)

        # Anchor: the first run actually completed some steps, otherwise
        # "stays done" is vacuous.
        assert done_before != [], "expected the first run to have completed earlier steps"

        done_after = done_steps(context.html)

        for step <- done_before do
          assert step in done_after,
                 "expected #{step} to remain done across the re-run"
        end

        {:ok, context}
      end

      then_ "setup resumed at the email step rather than the beginning", context do
        assert context.html =~ ~r/data-step="email"[^>]*data-state="(running|done)"/,
               "expected the re-run to pick the email step back up"

        {:ok, context}
      end
    end
  end

  defp done_steps(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("[data-test='setup-step'][data-state='done']")
    |> Enum.map(&(Floki.attribute(&1, "data-step") |> List.first()))
  end
end
