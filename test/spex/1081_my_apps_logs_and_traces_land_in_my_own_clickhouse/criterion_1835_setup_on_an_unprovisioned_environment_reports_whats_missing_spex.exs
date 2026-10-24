defmodule CodeMySpecSpex.Story1081.Criterion1835Spex do
  @moduledoc """
  Story 1081 -- My app's logs and traces land in my own ClickHouse
  Criterion 1835 -- Setup on an unprovisioned environment reports what's missing.

  Twin of criterion 1709, phrased generically rather than naming UAT.

  Surface: `CodeMySpecWeb.ConsoleLive` on the cloud app, driving the
  `:telemetry` step's own precondition check.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers
  setup :fake_working_directory

  spex "Setup on an unprovisioned environment reports what's missing", criterion: 1835 do
    scenario "the run reports the missing prerequisite instead of proceeding" do
      given_ "an environment has no provisioned server", context do
        {:ok, view, _html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/console/resources/telemetry?env=uat"
          )

        {:ok, Map.put(context, :view, view)}
      end

      when_ "Sam runs telemetry setup for that environment", context do
        run_console_step(context.view, :telemetry)
        await_console_step(context.view, :telemetry)

        {:ok, Map.put(context, :html, render(context.view))}
      end

      then_ "setup reports what is missing instead of proceeding", context do
        refute resource_step_state?(context.html, "telemetry", "done"),
               "expected the run to stop rather than report done"

        step_text =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='resource-step'][data-step='telemetry']")
          |> Floki.text()

        assert String.trim(step_text) != "",
               "expected the stopped step to say what is missing"

        {:ok, context}
      end
    end
  end
end
