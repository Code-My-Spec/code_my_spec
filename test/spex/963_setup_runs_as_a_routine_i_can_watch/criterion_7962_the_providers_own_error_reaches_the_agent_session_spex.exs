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
  @given_cassette "963_7962_credentials"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :connect_providers

  spex "The provider's own error reaches the agent session" do
    scenario "the escalation carries the step, the attempt and the provider's message" do
      given_ "the domain step failed because the token lacks Registrar write", context do
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

        # A credential Cloudflare itself rejects, so the domain step fails with
        # *Cloudflare's* message rather than ours. "The provider's own error
        # reaches the agent session" cannot be observed on a run where the
        # provider was never asked.
        break_provider_credential(context.scope, :cloudflare)

        with_provider_cassette(@cassette, fn ->
          view
          |> element("[data-test='start-setup']")
          |> render_click()

          # Started, not finished: the click returns as soon as the run
          # begins, so the page is read once the run settles.
          await_provisioning(view)

          # The repository a previous recording made cannot be deleted (no
          # `delete_repo` scope), so the run pauses on the name. Adopting is the
          # honest answer and lets the steps under test actually run.
          adopt_repository_if_paused(view)
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
