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

  @first_run_cassette "963_7963_setup_run_stops_at_email"
  @resume_cassette "setup_resume_from_email_ok"
  @given_cassette "963_7963_credentials"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :connect_providers

  spex "A re-run picks up where it stopped" do
    scenario "the earlier steps stay done and the run resumes at the email step" do
      given_ "setup stopped at the email step with earlier steps succeeded", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        # Hetzner has no OAuth, so its token is pasted per project — without it
        # the server step stops at `hetzner_not_configured` and every claim
        # downstream fails for a reason that is not the one under test. Saving a
        # credential proves it with a real provider call, so it belongs inside a
        # cassette.
        tear_down_after(context.scope, [:server])

        # The repository too, so the next recording starts from one that does not
        # exist — a repository carrying an earlier run's commits rejects a fresh
        # push as non-fast-forward (which is 8184's subject, not this one's).
        tear_down_repository(context.project)

        # The repository an earlier recording made still exists, so setup would
        # pause asking whose it is. It is this project's — stating that lets the
        # run reach the steps under test.
        own_repository(context.project)

        with_provider_cassette(@given_cassette, fn ->
          paste_provider_credentials(view)
        end)

        with_provider_cassette(@first_run_cassette, fn ->
          view |> element("[data-test='start-setup']") |> render_click()

          # The repository an earlier recording made cannot be deleted (the grant
          # has no `delete_repo` scope), so the run pauses on the name and every
          # step under test stays not_started. Adopting is the honest answer.
          adopt_repository_if_paused(view)
        end)

        html = render(view)

        assert html =~ ~r/data-step="email"[^>]*data-state="errored"/,
               "expected the first run to stop at the email step"

        {:ok, context |> Map.put(:view, view) |> Map.put(:first_run_html, html)}
      end

      when_ "Sam fixes the credential and runs setup again", context do
        with_provider_cassette(@resume_cassette, fn ->
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
