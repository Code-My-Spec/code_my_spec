defmodule CodeMySpecSpex.Story963.Criterion7971Spex do
  @moduledoc """
  Story 963 — Setup runs as a routine I can watch
  Criterion 7971 — Sam retries one errored step without re-running the rest.

  The status page offers a retry per step, and using it runs only that
  step. The other steps stay exactly as they were — a retry that
  re-executed the whole plan would re-touch working infrastructure to fix
  one broken piece.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @stopped_cassette "963_7971_setup_run_stops_at_email"
  @retry_cassette "resend_domain_verify_ok"
  @given_cassette "963_7971_credentials"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :connect_providers

  spex "Sam retries one errored step without re-running the rest" do
    scenario "retrying the email step leaves every other step untouched" do
      given_ "the status page shows the email step errored and the others done", context do
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

        with_provider_cassette(@stopped_cassette, fn ->
          view |> element("[data-test='start-setup']") |> render_click()

          # The repository an earlier recording made cannot be deleted (the grant
          # has no `delete_repo` scope), so the run pauses on the name and every
          # step under test stays not_started. Adopting is the honest answer.
          adopt_repository_if_paused(view)
        end)

        before = render(view)

        assert before =~ ~r/data-step="email"[^>]*data-state="errored"/,
               "expected the email step to be errored before the retry"

        {:ok, context |> Map.put(:view, view) |> Map.put(:before, before)}
      end

      when_ "Sam retries the email step", context do
        with_provider_cassette(@retry_cassette, fn ->
          context.view
          |> element("[data-test='setup-step'][data-step='email'] [data-test='retry-step']")
          |> render_click()
        end)

        {:ok, Map.put(context, :html, render(context.view))}
      end

      then_ "the email step moves to done", context do
        assert context.html =~ ~r/data-step="email"[^>]*data-state="done"/,
               "expected the retried step to succeed"

        {:ok, context}
      end

      then_ "every other step is exactly as it was", context do
        before_states = step_states(context.before) |> Map.delete("email")
        after_states = step_states(context.html) |> Map.delete("email")

        # Anchor: there were other steps to leave alone.
        assert map_size(before_states) > 0, "expected other steps to exist alongside email"

        assert after_states == before_states,
               "expected no other step to change on a single-step retry:\n  before: #{inspect(before_states)}\n  after:  #{inspect(after_states)}"

        {:ok, context}
      end
    end
  end

  defp step_states(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("[data-test='setup-step']")
    |> Map.new(fn el ->
      {el |> Floki.attribute("data-step") |> List.first(),
       el |> Floki.attribute("data-state") |> List.first()}
    end)
  end
end
