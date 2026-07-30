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

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The agent fixes the failure and setup carries on unattended" do
    scenario "a DNS conflict is repaired and the run completes without Sam" do
      given_ "setup is running and the DNS step will hit a conflicting record", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the DNS step fails and the setup agent takes over", context do
        ReqCassette.with_cassette(@conflict_cassette, [mode: :replay], fn ->
          context.view |> element("[data-test='start-setup']") |> render_click()
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
