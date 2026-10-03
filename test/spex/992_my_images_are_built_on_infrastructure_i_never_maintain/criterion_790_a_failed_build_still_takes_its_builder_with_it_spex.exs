defmodule CodeMySpecSpex.Story992.Criterion8237Spex do
  @moduledoc """
  Story 992 — My images are built on infrastructure I never maintain
  Criterion 8237 — A failed build still takes its builder with it.

  8236's failure path, and the one that actually rots. A successful deploy that
  leaked a box at least has someone looking at it; a failed deploy already
  looks like a failure, so a leak adds nothing visible to it. Nobody goes
  looking, and the box keeps billing.

  A build fails for ordinary reasons — a syntax error, a disk that filled — so
  this is the common case rather than the exotic one. Story 877 moved the box
  itself onto a shared, persistent one, so what has to survive a failure
  unconditionally is not "destroy" any more, it is "ask the same release
  question a success asks" — the exact same `BurstBox.Lifecycle.check/3` call,
  on the exact same box, whether the build that just ran on it succeeded or
  not. This scenario stages the same due-and-idle box 789 does, on the failure
  path, to prove the two get identical treatment rather than failure quietly
  skipping the check a success remembers to make.

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

  spex "A failed build still takes its builder with it", criterion: 790 do
    scenario "a build that fails on a due, idle shared box still gets it released" do
      given_ "Sam's build is going to fail, on a shared box that is due for its end-of-hour check and idle",
             context do
        {:ok, built_deploy_run(context, builds: :error, box_release: :idle)}
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

      then_ "nothing was published", context do
        document = Floki.parse_document!(context.html)

        assert Floki.find(document, "[data-test='published-image']") == [],
               "a build that failed published an image anyway"

        {:ok, Map.put(context, :document, document)}
      end

      then_ "and the box was still released, the same as a success would be", context do
        builder = Floki.find(context.document, "[data-test='builder']")

        assert builder != [],
               "the failed deploy recorded no box, so nothing says whether it is still running"

        assert Floki.attribute(builder, "data-destroyed") == ["true"],
               "the build failed and the box it ran on — due for a check, and idle — was " <>
                 "left running anyway: the leak nobody goes looking for, because the deploy " <>
                 "already looked like a failure"

        {:ok, context}
      end
    end
  end
end
