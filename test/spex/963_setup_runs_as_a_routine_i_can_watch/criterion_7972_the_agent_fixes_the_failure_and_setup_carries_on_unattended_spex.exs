defmodule CodeMySpecSpex.Story963.Criterion7972Spex do
  @moduledoc """
  Story 963 — Setup runs as a routine I can watch
  Criterion 7972 — The agent fixes the failure and setup carries on unattended.

  Escalation is automatic and it repairs rather than merely reports. A DNS
  step that fails on a conflicting record hands off to the setup agent,
  the agent resolves the conflict, and setup continues from that step —
  Sam comes back to a finished run, not to a question.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @conflict_cassette "cloudflare_dns_record_conflict_then_resolved"
  @given_cassette "963_7972_credentials"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :connect_providers

  spex "The agent fixes the failure and setup carries on unattended" do
    scenario "a DNS conflict is repaired and the run completes without Sam" do
      given_ "setup is running and the DNS step will hit a conflicting record", context do
        # Before the page mounts. The LiveView reads the project once, at mount;
        # claiming the repository afterwards updates the row but not the socket,
        # so the step still saw a repository belonging to nobody and paused.
        own_repository(context.project)

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


        with_provider_cassette(@given_cassette, fn ->
          paste_provider_credentials(view)
        end)

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the DNS step fails and the setup agent takes over", context do
        with_provider_cassette(@conflict_cassette, fn ->
          context.view |> element("[data-test='start-setup']") |> render_click()

          # The repository an earlier recording made cannot be deleted (the grant
          # has no `delete_repo` scope), so the run pauses on the name and every
          # step under test stays not_started. Adopting is the honest answer.
          adopt_repository_if_paused(context.view)
        end)

        {:ok, Map.put(context, :html, render(context.view))}
      end

      then_ "the escalation happened without Sam asking for it", context do
        assert has_element?(
                 context.view,
                 "[data-test='setup-step'][data-step='dns'] [data-test='escalation'][data-trigger='automatic']"
               ),
               "expected the escalation to be automatic rather than requiring Sam to press anything"

        {:ok, context}
      end

      then_ "setup continued from the DNS step and finished", context do
        assert context.html =~ ~r/data-step="dns"[^>]*data-state="done"/,
               "expected the DNS step to end up done after the agent resolved the conflict"

        refute context.html =~ ~r/data-state="errored"/,
               "expected no step left errored once the agent had repaired the failure"

        {:ok, context}
      end
    end
  end
end
