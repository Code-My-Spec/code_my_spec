defmodule CodeMySpecSpex.Story1081.Criterion1718Spex do
  @moduledoc """
  Story 1081 -- My app's logs and traces land in my own ClickHouse
  Criterion 1718 -- Telemetry shows unchecked until Sam checks it.

  Checks are manual only (`Provisioning.Step`'s own documented design) --
  nothing re-verifies a step on mount, on a timer, or as a side effect.

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

  spex "Telemetry shows unchecked until Sam checks it", criterion: 1718 do
    scenario "the panel reads unchecked before anyone has run a check" do
      given_ "UAT telemetry was set up an hour ago and never checked", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/telemetry?env=uat")

        run_console_step(view, :telemetry)
        await_console_step(view, :telemetry)

        {:ok, context}
      end

      when_ "Sam opens the Telemetry resource", context do
        {:ok, checks_view, html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/console/resources/telemetry?env=uat&tab=checks"
          )

        {:ok, context |> Map.put(:checks_view, checks_view) |> Map.put(:html, html)}
      end

      then_ "its status reads unchecked", context do
        assert context.html =~
                 ~r/data-test="diagnostics-checked-note"[^>]*>\s*unchecked/,
               "expected the telemetry panel to read unchecked before any check has run"

        {:ok, context}
      end
    end
  end
end
