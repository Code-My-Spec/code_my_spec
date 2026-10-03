defmodule CodeMySpecSpex.Story1086.Criterion1762Spex do
  @moduledoc """
  Story 1086 — I see every change made to my project's setup
  Criterion 1762 — Sam's deploy appears in Activity.

  Deploys gets its own named entry rather than folding into "provision" —
  it's the action Harness called out by name when this gate was scoped, and
  it's the one a project owner most wants an answer about: did my change
  actually ship.

  Surface: `CodeMySpecWeb.ConsoleLive` on the cloud app, driving
  `CodeMySpec.Activity`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :connect_providers

  spex "Sam's deploy appears in Activity", criterion: 1762 do
    scenario "deploying to uat leaves an entry naming the environment" do
      given_ "setup trivially succeeds end to end", context do
        {:ok, context} = {:ok, scripted_run(context)}
        {:ok, context}
      end

      when_ "Sam deploys uat from the console's Deploys page", context do
        {:ok, deploys_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/deploys")

        deploys_view
        |> form(
          "[data-test='deploy-row'][data-environment='uat'] [data-test='deploy-environment-form']",
          %{"environment" => "uat"}
        )
        |> render_submit()

        {:ok, context}
      end

      then_ "the deploy appears in Activity, naming uat", context do
        {:ok, activity_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/activity")

        document = activity_view |> render() |> Floki.parse_document!()

        entries =
          document
          |> Floki.find("[data-test='activity-entry'][data-kind='deploy']")

        assert entries != [], "the deploy never reached Activity at all"

        assert Floki.attribute(entries, "data-environment") == ["uat"],
               "the deploy entry does not name which environment shipped"

        assert Floki.attribute(entries, "data-resource") == ["deploys"],
               "the deploy entry should scope to the deploys resource"

        {:ok, context}
      end
    end
  end
end
