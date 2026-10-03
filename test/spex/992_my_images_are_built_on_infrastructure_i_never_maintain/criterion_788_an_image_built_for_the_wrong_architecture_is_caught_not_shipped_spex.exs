defmodule CodeMySpecSpex.Story992.Criterion8235Spex do
  @moduledoc """
  Story 992 — My images are built on infrastructure I never maintain
  Criterion 8235 — An image built for the wrong architecture is caught, not
  shipped.

  8234's failure path, and the reason the builder reads the architecture off
  the image it produced rather than echoing the one it was asked for: a check
  against your own request always passes.

  The failure this prevents is a deploy that succeeds. The image publishes, the
  swap runs, and the container dies at start — by which point the deploy has
  already reported itself healthy. So the assertion is a negative: nothing was
  published, and the step did not call itself done.

  Retargeted onto the console (provisioning-console-step6, unmerged): the
  deploy step's own markup (`DeployConfig`) is unchanged — it was reused
  as-is — only the page it's rendered under moved. The old page's single
  "start setup" button ran the whole step sequence to reach deploy; the
  console's deploy form runs `:deploy` alone, which is sufficient here since
  `built_deploy_run/2` scripts every other step and nothing in this criterion
  reads them.

  Surface: `CodeMySpecWeb.ConsoleLive`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  # Fakes rather than cassettes: these criteria drive the deploy step, whose
  # Hetzner calls fall outside every cassette — `cannot find mock/stub`,
  # reported as whatever the criterion was asserting.
  setup :fake_providers
  setup :real_working_directory

  spex "An image built for the wrong architecture is caught, not shipped", criterion: 788 do
    scenario "a build that produced the other architecture publishes nothing" do
      given_ "Sam's environment runs on arm but the build produces x86", context do
        {:ok, built_deploy_run(context, architecture: :arm, builds: :x86)}
      end

      when_ "he deploys", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/deploys")

        view
        |> form(
          "[data-test='deploy-row'][data-step='deploy'][data-environment='uat'] " <>
            "[data-test='deploy-environment-form']",
          %{"environment" => "uat"}
        )
        |> render_submit()

        {:ok, Map.put(context, :html, render(view))}
      end

      then_ "no image was published", context do
        document = Floki.parse_document!(context.html)

        assert Floki.find(document, "[data-test='published-image']") == [],
               "a mismatched image was published — it would deploy cleanly and die at " <>
                 "container start"

        {:ok, Map.put(context, :document, document)}
      end

      then_ "and the deploy did not report itself done", context do
        refute context.html =~ ~r/data-step="deploy"[^>]*data-state="done"/,
               "the deploy called itself done on a build it should have refused"

        {:ok, context}
      end
    end
  end
end
