defmodule CodeMySpecSpex.Story992.Criterion1737Spex do
  @moduledoc """
  Story 992, criterion 1737: a busy burst box remains available near the end
  of its billing hour and receives another check before the following hour.

  Two deploys use the same staged shared box. The first checks it at 00:58
  while another workload needs it; the second checks it at 01:58 after that
  workload has ended. The second outcome distinguishes a new check from a
  decision cached during the first hour.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers
  setup :real_working_directory

  spex "A busy burst box is kept and checked again before the following hour",
    criterion: 1737 do
    scenario "a busy box survives one billing boundary and is reconsidered at the next" do
      given_ "Sam's shared burst box is busy at minute 58 of its first billing hour",
             context do
        context = built_deploy_run(context, box_release: :busy, now: ~U[2026-01-01 00:58:00Z])

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/deploys")

        view
        |> form(
          "[data-test='deploy-row'][data-step='deploy'][data-environment='uat'] " <>
            "[data-test='deploy-environment-form']",
          %{"environment" => "uat"}
        )
        |> render_submit()

        {:ok, Map.put(context, :first_html, render(view))}
      end

      when_ "the box is idle near the end of its following billing hour", context do
        {:ok, deletions} = Agent.start_link(fn -> [] end)

        context =
          context
          |> built_deploy_run(
            box_release: :idle,
            now: ~U[2026-01-01 01:58:00Z],
            on_destroy: fn id -> Agent.update(deletions, &[id | &1]) end
          )
          |> Map.put(:deletions, deletions)

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/deploys")

        view
        |> form(
          "[data-test='deploy-row'][data-step='deploy'][data-environment='uat'] " <>
            "[data-test='deploy-environment-form']",
          %{"environment" => "uat"}
        )
        |> render_submit()

        {:ok, Map.put(context, :second_html, render(view))}
      end

      then_ "the first check kept the busy box and the following check released it",
            context do
        first = Floki.parse_document!(context.first_html)
        second = Floki.parse_document!(context.second_html)
        first_builder = Floki.find(first, "[data-test='builder']")
        second_builder = Floki.find(second, "[data-test='builder']")

        assert Floki.find(first, "[data-test='published-image']") != []
        assert first_builder != [], "the first deploy recorded no shared builder"
        assert Floki.attribute(first_builder, "data-destroyed") == ["false"]
        assert second_builder != [], "the next-hour deploy recorded no shared builder"
        assert Floki.attribute(second_builder, "data-destroyed") == ["true"]
        assert Agent.get(context.deletions, & &1) == [4242]

        {:ok, context}
      end
    end
  end
end
