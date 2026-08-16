defmodule CodeMySpecSpex.Story985.Criterion8183Spex do
  @moduledoc """
  Story 985 — My repository exists before anything needs to push
  Criterion 8183 — The step is proven by a push, not by the repository
  existing.

  The story's "so that it has a remote to push to" is the acceptance test. A
  repository that exists but has never been pushed to proves the API call
  worked, not that the harness has a remote — the credential could lack write
  access, the default branch could be protected, the installation could cover
  a different repository than the one named.

  Same shape as the deploy, content and widget steps: the artifact existing is
  not the finish line, the thing working is.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Repository`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers
  # A modelled shell over the memory filesystem: the repository step's proof
  # is a `git push`, which is a subprocess rather than an API call.
  setup :fake_working_directory

  spex "The step is proven by a push, not by the repository existing" do
    scenario "the step records the commit that landed and only then completes" do
      given_ "Sam is on the setup status page with GitHub connected", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the repository step runs", context do
        context.view
        |> element("[data-test='setup-step'][data-step='repository'] [data-test='run-step']")
        |> render_click()

        # Waited for, then read. The step runs under a supervised task — a deploy
        # or a push takes longer than a LiveView event may — so `render_click/1`
        # returns while it is still running and the page has not caught up.
        await_step(context.view, :repository)
        html = render(context.view)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "a push proof is recorded", context do
        proof =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='push-proof']")

        assert proof != [],
               "expected the step to record a push proof rather than only the repository"

        {:ok, Map.put(context, :proof, proof)}
      end

      then_ "the proof names the commit that landed", context do
        commit = context.proof |> Floki.attribute("data-commit") |> List.first()

        assert is_binary(commit) and commit != "",
               "expected the proof to name the commit that landed, got #{inspect(commit)}"

        {:ok, Map.put(context, :commit, commit)}
      end

      then_ "the step is done", context do
        assert context.html =~ ~r/data-step="repository"[^>]*data-state="done"/,
               "expected the step to complete once the push succeeded"

        {:ok, context}
      end
    end
  end
end
