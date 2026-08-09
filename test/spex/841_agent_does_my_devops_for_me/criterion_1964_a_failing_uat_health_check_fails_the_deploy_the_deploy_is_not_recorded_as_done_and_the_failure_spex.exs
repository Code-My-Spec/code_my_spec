defmodule CodeMySpecSpex.Story841.Criterion1964Spex do
  @moduledoc """
  Story 841 — Agent does my DevOps for me
  Criterion 1964 — A failing UAT health check fails the deploy.

  The criterion: the deploy is not recorded as done, and the failure surfaces
  as a problem for the loop and the user — a sick UAT never reads as shipped.

  Surface: `ProvisioningLive`, running the deploy step against a host whose
  health check does not pass. The page is where a deploy is recorded and where
  a person would see it, so both halves of the claim are observable there.

  ## Related to 1963's disagreement

  1963 asserts the loop hands out the UAT deploy; the graph no longer carries a
  deploy node. This criterion is narrower and still holds on the surface that
  survived: whatever *invokes* the deploy, an unhealthy one must not record as
  done. Driven through the page rather than the loop for that reason.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "841_1964_uat_health_check_fails"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :connect_providers

  spex "A failing UAT health check fails the deploy" do
    scenario "UAT comes up sick" do
      given_ "Sam is on the setup page with a deploy ready to run", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the deploy runs and UAT does not answer its health check", context do
        html =
          with_full_cassette @cassette do
            context.view
            |> element("[data-test='setup-step'][data-step='deploy'] [data-test='run-step']")
            |> render_click()

            render(context.view)
          end

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the deploy is not recorded as done", context do
        state =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='setup-step'][data-step='deploy']")
          |> Floki.attribute("data-state")
          |> List.first()

        refute state == "done",
               "a deploy whose health check failed read as done — a sick UAT must never read as shipped"

        assert state == "errored",
               "expected the failed health check to fail the deploy, got #{inspect(state)}"

        {:ok, context}
      end

      then_ "the failure is on the page for the user to see", context do
        escalation =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='escalation'][data-step='deploy']")
          |> Floki.text()

        assert escalation != "",
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
