defmodule CodeMySpecSpex.Story1081.Criterion1853Spex do
  @moduledoc """
  Story 1081 -- My app's logs and traces land in my own ClickHouse
  Criterion 1853 -- Re-running setup on a working stack is a no-op.

  Twin of criterion 1711, framed as nothing already-right changing.

  Surface: `CodeMySpecWeb.ConsoleLive` on the cloud app, driving the
  `:monitoring` step's idempotent re-run.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers
  setup :fake_working_directory
  setup :confirm_new_servers

  spex "Re-running setup on a working stack is a no-op", criterion: 1853 do
    scenario "nothing that was already right changes on a second run" do
      given_ "telemetry is already set up and working", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/servers?env=uat")

        run_console_step(view, :monitoring)
        await_console_step(view, :monitoring)

        html_before = render(view)

        resources_before =
          html_before
          |> Floki.parse_document!()
          |> Floki.find("[data-test='provisioned-resource']")
          |> Floki.attribute("data-identifier")

        {:ok, context |> Map.put(:view, view) |> Map.put(:resources_before, resources_before)}
      end

      when_ "Sam re-runs setup", context do
        run_console_step(context.view, :monitoring)
        await_console_step(context.view, :monitoring)

        {:ok, Map.put(context, :html, render(context.view))}
      end

      then_ "nothing that was already right changes", context do
        resources_after =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='provisioned-resource']")
          |> Floki.attribute("data-identifier")

        assert resources_after == context.resources_before,
               "expected a re-run on a working stack to change nothing already correct"

        {:ok, context}
      end
    end
  end
end
