defmodule CodeMySpecSpex.Story985.Criterion8184Spex do
  @moduledoc """
  Story 985 — My repository exists before anything needs to push
  Criterion 8184 — A repository that exists but rejects the push is not done.

  The other half of criterion 8183. When the repository is there but the push
  is refused — the installation does not cover it, the grant is read-only, the
  branch is protected — the step reports the push failure rather than the
  repository's existence, and does not complete.

  Reporting "repository created" here would be true and useless: Sam would
  believe he has a remote, and the first thing the harness tried to push would
  fail somewhere far from setup.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Repository`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "github_repo_exists_push_rejected"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A repository that exists but rejects the push is not done" do
    scenario "the step reports the push failure and stays incomplete" do
      given_ "Sam is on the setup status page and the repository already exists", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the repository step runs and the push is refused", context do
        html =
          ReqCassette.with_cassette(@cassette, [mode: :replay], fn ->
            context.view
            |> element("[data-test='setup-step'][data-step='repository'] [data-test='run-step']")
            |> render_click()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the step does not complete", context do
        refute context.html =~ ~r/data-step="repository"[^>]*data-state="done"/,
               "expected a rejected push to leave the step incomplete"

        {:ok, context}
      end

      then_ "the reported failure is about the push, not the repository", context do
        text =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='setup-step'][data-step='repository']")
          |> Floki.text()

        assert text =~ ~r/push/i,
               "expected the failure to name the push, got: #{inspect(String.slice(text, 0, 200))}"

        {:ok, context}
      end

      then_ "no push proof is recorded", context do
        proof =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='push-proof']")

        assert proof == [],
               "expected no push proof when the push was refused"

        {:ok, context}
      end
    end
  end
end
