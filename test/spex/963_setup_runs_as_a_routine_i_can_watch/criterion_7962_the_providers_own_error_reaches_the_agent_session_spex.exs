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

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers

  spex "The provider's own error reaches the agent session" do
    scenario "the escalation carries what the provider actually said" do
      given_ "a step failed with the provider's own message", context do
        # The claim is about plumbing: whatever the provider said arrives
        # intact in the session, rather than being replaced by a message of
        # ours. A scripted message tests that better than a real one — it is
        # distinctive enough that finding it verbatim on the page proves it
        # travelled rather than proving something merely went wrong.
        context =
          scripted_run(context, %{
            domain: {:error, "Registrar refused to register the domain: token lacks Zone:Edit"}
          })

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        view |> element("[data-test='start-setup']") |> render_click()
        await_provisioning(view)

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
