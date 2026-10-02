defmodule CodeMySpecSpex.Story841.Criterion1964Spex do
  @moduledoc """
  Story 841 — Agent does my DevOps for me
  Criterion 1964 — A failing UAT health check fails the deploy.

  The criterion: the deploy is not recorded as done, and the failure surfaces
  as a problem for the loop and the user — a sick UAT never reads as shipped.

  Retargeted onto the console (provisioning-console-step6, unmerged): deploy
  is its own page now (`/console/deploys`), not a resource group — see
  criterion 785's moduledoc. Its per-step card is `[data-test='deploy-row']`
  rather than `[data-test='setup-step']`, and it is not built on
  `ResourceDetail`, so it carries none of that component's generic
  `escalation` markup. The failure still surfaces, through `DeployConfig`'s
  own `boot-failure` paragraph (gated on `state == :errored and
  provider_error`, which a failed health check sets same as any other errored
  step) — so the second `then_` now reads that instead of `escalation`.

  Surface: `CodeMySpecWeb.ConsoleLive`, running the deploy step against a host
  whose health check does not pass. The page is where a deploy is recorded and
  where a person would see it, so both halves of the claim are observable
  there.

  ## Related to 1963's disagreement

  1963 asserts the loop hands out the UAT deploy; the graph no longer carries a
  deploy node. This criterion is narrower and still holds on the surface that
  survived: whatever *invokes* the deploy, an unhealthy one must not record as
  done. Driven through the page rather than the loop for that reason.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers

  spex "A failing UAT health check fails the deploy", criterion: 533 do
    scenario "UAT comes up sick" do
      given_ "Sam is on the setup page with a deploy ready to run", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/deploys?env=uat")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the deploy runs and UAT does not answer its health check", context do
        context.view
        |> form("[data-test='deploy-environment-form']", %{"environment" => "uat"})
        |> render_submit()

        html = render(context.view)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the deploy is not recorded as done", context do
        state =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='deploy-row'][data-step='deploy'][data-environment='uat']")
          |> Floki.attribute("data-state")
          |> List.first()

        refute state == "done",
               "a deploy whose health check failed read as done — a sick UAT must never read as shipped"

        assert state == "errored",
               "expected the failed health check to fail the deploy, got #{inspect(state)}"

        {:ok, context}
      end

      then_ "the failure is on the page for the user to see", context do
        failure =
          context.html
          |> Floki.parse_document!()
          |> Floki.find(
            "[data-test='deploy-row'][data-step='deploy'][data-environment='uat'] [data-test='boot-failure']"
          )
          |> Floki.text()

        assert failure != "",
               "expected the health-check failure to surface rather than being swallowed"

        {:ok, context}
      end

      then_ "no live version is claimed", context do
        refute context.html =~ ~s(data-test="live-version"),
               "expected nothing to claim a live version when the deploy did not pass its health check"

        {:ok, context}
      end
    end
  end
end
