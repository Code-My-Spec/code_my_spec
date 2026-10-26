defmodule CodeMySpecSpex.Story992.Criterion1736Spex do
  @moduledoc """
  Story 992, criterion 1736: an idle burst box due for its end-of-hour
  check is deleted before another billing hour begins.

  The deploy console drives the real build and its lifecycle check. The
  shared box is staged as created at 00:00 and the check runs at 00:58,
  leaving two minutes before the next billing hour.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers
  setup :real_working_directory

  spex "An idle burst box is deleted before the next billing hour", criterion: 1736 do
    scenario "an idle box is released at its end-of-hour check" do
      given_ "Sam's shared burst box is idle at minute 58 of its billing hour", context do
        {:ok, deletions} = Agent.start_link(fn -> [] end)

        context =
          built_deploy_run(context,
            box_release: :idle,
            on_destroy: fn id -> Agent.update(deletions, &[id | &1]) end
          )

        {:ok, Map.put(context, :deletions, deletions)}
      end

      when_ "Sam deploys an image on the shared box", context do
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

      then_ "the image exists and the idle box is deleted before the hour rolls over", context do
        document = Floki.parse_document!(context.html)
        assert Floki.find(document, "[data-test='published-image']") != []

        builder = Floki.find(document, "[data-test='builder']")
        assert builder != [], "the deploy recorded no shared builder"
        assert Floki.attribute(builder, "data-destroyed") == ["true"]
        assert Agent.get(context.deletions, & &1) == [4242]

        {:ok, context}
      end
    end
  end
end
