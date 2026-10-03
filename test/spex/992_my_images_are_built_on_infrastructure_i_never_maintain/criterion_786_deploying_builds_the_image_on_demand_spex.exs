defmodule CodeMySpecSpex.Story992.Criterion8233Spex do
  @moduledoc """
  Story 992 — My images are built on infrastructure I never maintain
  Criterion 8233 — Deploying builds the image on demand.

  The other half of 8232. Creating a project builds nothing; deploying is the
  moment a build happens, because it is the first moment anyone knows what to
  build.

  The build itself is injected. A container build is minutes of output with
  non-deterministic layer digests, invalidated by any Dockerfile edit, and it
  would prove Docker works rather than anything of ours. What is ours — that a
  deploy asks for a build at all, and records what came back — is what this
  asserts, through the page.

  Retargeted onto the console (provisioning-console-step6, unmerged): the
  deploy step's own markup (`DeployConfig`) is unchanged — it was reused
  as-is — only the page it's rendered under moved. The old page's single
  "start setup" button ran the whole step sequence to reach deploy; the
  console's deploy form runs `:deploy` alone, which is sufficient here since
  `built_deploy_run/2` scripts every other step and nothing in this criterion
  reads them.

  Surface: `CodeMySpecWeb.ConsoleLive`, driving
  `CodeMySpec.Provisioning.Builder` through the deploy step.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  # Setup refuses to start while a credential is missing (criterion 7985), so
  # without this the run never begins and this criterion reports "nothing was
  # built" — which is true, and nothing to do with what it is asking.
  # Fakes rather than cassettes: these criteria drive the deploy step, whose
  # Hetzner calls fall outside every cassette — `cannot find mock/stub`,
  # reported as whatever the criterion was asserting.
  setup :fake_providers
  setup :real_working_directory

  spex "Deploying builds the image on demand", criterion: 786 do
    scenario "the deploy step builds and records the image it produced" do
      given_ "Sam has a project that has never been built", context do
        {:ok, built_deploy_run(context)}
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

      then_ "the image the deploy runs was built by this deploy", context do
        image =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='published-image']")
          |> List.first()

        assert image, "the deploy recorded no image at all"

        assert Floki.attribute([image], "data-built") == ["true"],
               "the deploy ran an image it did not build — 8233 is that deploying is " <>
                 "what causes a build"

        # Tagged by the commit, so "which image is this" and "which code is
        # this" are not two questions.
        assert [reference] = Floki.attribute([image], "data-image")
        assert reference =~ ~r/:[0-9a-f]{12}$/, "expected the image tagged by its commit"

        {:ok, context}
      end
    end
  end
end
