defmodule CodeMySpecSpex.Story992.Criterion8239Spex do
  @moduledoc """
  Story 992 — My images are built on infrastructure I never maintain
  Criterion 8239 — A deploy does not pay for the toolchain every time.

  Originally: a builder was created per build, so whatever it had to install,
  it installed on every deploy. Starting from a bare OS means `apt-get install
  docker` before any work begins: a minute or two of Sam's deploy, and a
  dependency on apt mirrors being up at that moment — a deploy that fails for
  reasons that have nothing to do with his code.

  Story 877 made the answer stronger than "boots from a pre-warmed image": the
  box is not even recreated between builds any more, so the toolchain stays
  warm across every deploy, not just within the one Hetzner snapshotted ahead
  of time. What a build boots from is still the deciding fact, so this is
  still asserted on the box's own recorded image rather than on timing —
  timing a build would measure Hetzner, not the decision.

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

  spex "A deploy does not pay for the toolchain every time", criterion: 791 do
    scenario "the box boots from an image that already has the toolchain" do
      given_ "Sam has a project ready to deploy", context do
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

      then_ "the box booted from the pre-warmed burst-box image, not a bare OS", context do
        builder =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='builder']")

        assert builder != [], "the deploy did not record what the box booted from"

        assert [booted_from] = Floki.attribute(builder, "data-booted-from")

        # The burst-box snapshot's own description (`Builder.server_image/1`
        # reads it straight off the box's live Hetzner record, sanitized to
        # one token so the space-splitting `identifier_field/2` format round
        # trips it intact) — kamal and docker-ce already installed. A bare
        # OS would name a distribution, and every deploy would then install
        # the toolchain before starting work.
        assert booted_from =~ "burst_box",
               "the box booted from #{booted_from}, so every deploy pays to install " <>
                 "the toolchain before it can build anything"

        {:ok, context}
      end
    end
  end
end
