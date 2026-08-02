defmodule CodeMySpecSpex.Story985.Criterion8182Spex do
  @moduledoc """
  Story 985 — My repository exists before anything needs to push
  Criterion 8182 — The remote is in place before the first build needs it.

  The repository step finishes before the deploy step starts. CI publishes the
  image the deploy pulls by commit SHA, so a deploy that runs before there is
  a remote has nothing to build from — and the failure surfaces several steps
  away from its cause.

  The ordering is asserted from recorded timestamps rather than from the step
  list's rendering order, because ordering is what matters and a list can be
  sorted for display.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Repository`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "setup_run_repository_then_deploy"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The remote is in place before the first build needs it" do
    scenario "the repository step completes before the deploy step starts" do
      given_ "Sam is on the setup status page for a brand new project", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "he runs setup", context do
        html =
          ReqCassette.with_cassette(@cassette, [mode: :replay], fn ->
            context.view
            |> element("[data-test='start-setup']")
            |> render_click()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the repository step records when it finished", context do
        finished =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='setup-step'][data-step='repository']")
          |> Floki.attribute("data-finished-at")
          |> List.first()

        assert is_binary(finished) and finished != "",
               "expected the repository step to record when it finished"

        {:ok, Map.put(context, :repo_finished_at, finished)}
      end

      then_ "the deploy step started after it", context do
        started =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='setup-step'][data-step='deploy']")
          |> Floki.attribute("data-started-at")
          |> List.first()

        assert is_binary(started) and started != "",
               "expected the deploy step to record when it started"

        assert context.repo_finished_at <= started,
               "expected the repository to exist before the deploy needed it — " <>
                 "repository finished #{context.repo_finished_at}, deploy started #{started}"

        {:ok, context}
      end
    end
  end
end
