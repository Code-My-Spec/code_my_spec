defmodule CodeMySpecSpex.Story985.Criterion8181Spex do
  @moduledoc """
  Story 985 — My repository exists before anything needs to push
  Criterion 8181 — A revoked GitHub connection stops the step rather than
  falling back.

  When Sam has revoked the installation, the step stops and tells him to
  reconnect. It does not reach for any other credential — not a platform
  token, not a machine account, not a locally-authenticated `gh`. A fallback
  credential would create the repository under the wrong account and look
  like success.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Repository`.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "github_installation_revoked"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :connect_providers

  spex "A revoked GitHub connection stops the step rather than falling back" do
    scenario "the step stops and asks Sam to reconnect" do
      given_ "Sam is on the setup status page having revoked the installation", context do
        # The repository this makes lives in the throwaway organisation and goes
        # away with the spex, so the next recording starts from one that is not there.
        tear_down_repository(context.project)

        # Actually revoke it. The criterion's premise is a connection that no
        # longer works, and nothing here made that true — so the step ran
        # against a healthy grant, completed, and the assertion that it must
        # not complete was the only thing that noticed.
        break_provider_credential(context.scope, :github)

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the repository step runs", context do
        html =
          with_full_cassette @cassette do
            context.view
            |> element("[data-test='setup-step'][data-step='repository'] [data-test='run-step']")
            |> render_click()
          end

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the step does not complete", context do
        refute context.html =~ ~r/data-step="repository"[^>]*data-state="done"/,
               "expected a revoked connection to stop the step, not complete it"

        {:ok, context}
      end

      then_ "it tells Sam to reconnect", context do
        text =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='setup-step'][data-step='repository']")
          |> Floki.text()

        assert text =~ ~r/reconnect|connect .*github|authorize/i,
               "expected the step to name reconnecting GitHub, got: #{inspect(String.slice(text, 0, 200))}"

        {:ok, context}
      end

      then_ "no repository was created under any other account", context do
        refute context.html =~ ~r/data-kind="repository"[^>]*data-disposition="created"/,
               "expected no repository to be created via a fallback credential"

        {:ok, context}
      end
    end
  end
end
