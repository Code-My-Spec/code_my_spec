defmodule CodeMySpecSpex.Story1081.Criterion1855Spex do
  @moduledoc """
  Story 1081 -- My app's logs and traces land in my own ClickHouse
  Criterion 1855 -- Later deploys ship traces automatically.

  Twin of criterion 1713.

  Surface: `CodeMySpecWeb.ConsoleLive` on the cloud app, driving the
  `:deploy` step once `:monitoring` has run.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers
  setup :fake_working_directory
  setup :confirm_new_servers

  spex "Later deploys ship traces automatically", criterion: 1855 do
    scenario "a later deploy ships traces with no manual telemetry configuration" do
      given_ "telemetry setup has run once for Sam's project", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/servers?env=uat")

        run_console_step(view, :monitoring)
        await_console_step(view, :monitoring)

        {:ok, Map.put(context, :view, view)}
      end

      when_ "Sam deploys a new release", context do
        run_console_step(context.view, :deploy)
        await_console_step(context.view, :deploy)

        {:ok, Map.put(context, :html, render(context.view))}
      end

      then_ "traces ship automatically with no manual telemetry configuration", context do
        assert resource_step_state?(context.html, "deploy", "done"),
               "expected the deploy to ship traces automatically"

        {:ok, context}
      end
    end
  end
end
