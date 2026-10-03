defmodule CodeMySpecSpex.Story1081.Criterion1860Spex do
  @moduledoc """
  Story 1081 -- My app's logs and traces land in my own ClickHouse
  Criterion 1860 -- Telemetry shows unchecked until the owner checks it.

  Twin of criterion 1718.

  Surface: `CodeMySpecWeb.ConsoleLive`'s Checks tab.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers
  setup :fake_working_directory
  setup :confirm_new_servers

  spex "Telemetry shows unchecked until the owner checks it", criterion: 1860 do
    scenario "nothing checks on its own, so the panel reads unchecked" do
      given_ "a project's telemetry has never been checked", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/servers?env=uat")

        run_console_step(view, :monitoring)
        await_console_step(view, :monitoring)

        {:ok, context}
      end

      when_ "Sam views the Telemetry resource without checking it", context do
        {:ok, _checks_view, html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/console/resources/servers?env=uat&tab=checks"
          )

        {:ok, Map.put(context, :html, html)}
      end

      then_ "it shows as unchecked, since nothing checks on its own", context do
        assert context.html =~
                 ~r/data-test="diagnostics-checked-note"[^>]*>\s*unchecked/,
               "expected the panel to read unchecked since nothing checks on its own"

        {:ok, context}
      end
    end
  end
end
