defmodule CodeMySpecSpex.Story963.Criterion7962Spex do
  @moduledoc """
  Story 963 — Setup runs as a routine I can watch
  Criterion 7962 — The provider's own error reaches the agent session.

  When a step fails and escalates, the setup agent receives which step
  failed, what it attempted, and the provider's own error text — not a
  generic "domain step failed". Sam should not have to restate the
  problem, and a repair agent that cannot see the provider's words is
  guessing.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app — the
  escalation record is what the page exposes for the agent to pick up.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "cloudflare_domain_register_permission_denied"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The provider's own error reaches the agent session" do
    scenario "the escalation carries the step, the attempt and the provider's message" do
      given_ "the domain step failed because the token lacks Registrar write", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        ReqCassette.with_cassette(@cassette, [mode: :replay], fn ->
          view
          |> element("[data-test='start-setup']")
          |> render_click()
        end)

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the setup agent session opens for that failure", context do
        html =
          context.view
          |> element("[data-test='setup-step'][data-step='domain'] [data-test='escalation']")
          |> render()

        {:ok, Map.put(context, :escalation, html)}
      end

      then_ "it names which step failed and what it attempted", context do
        assert context.escalation =~ "domain",
               "expected the escalation to name the failed step"

        assert context.escalation =~ ~r/register/i,
               "expected the escalation to say what the step attempted"

        {:ok, context}
      end

      then_ "it carries the provider's own error text", context do
        assert context.escalation =~ ~r/Registrar/,
               "expected Cloudflare's own permission error to reach the escalation, not a generic message"

        {:ok, context}
      end
    end
  end
end
