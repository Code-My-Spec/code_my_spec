defmodule CodeMySpecSpex.Story1081.Criterion1709Spex do
  @moduledoc """
  Story 1081 -- My app's logs and traces land in my own ClickHouse
  Criterion 1709 -- Setup on an environment with no server says what's missing.

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

  spex "Setup on an environment with no server says what's missing", criterion: 1709 do
    scenario "the step stops naming the missing server instead of proceeding" do
      given_ "Sam's project has no UAT server yet", context do
        {:ok, view, _html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/console/resources/telemetry?env=uat"
          )

        {:ok, Map.put(context, :view, view)}
      end

      when_ "Sam runs the telemetry setup step for UAT", context do
        run_console_step(context.view, :telemetry)
        await_console_step(context.view, :telemetry)

        {:ok, Map.put(context, :html, render(context.view))}
      end

      then_ "it stops and says a server must be set up first", context do
        refute resource_step_state?(context.html, "telemetry", "done"),
               "expected the step to stop rather than report done with no server"

        step_text =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='resource-step'][data-step='telemetry']")
          |> Floki.text()

        assert step_text =~ ~r/server/i,
               "expected the stopped step to say a server must be set up first"

        {:ok, context}
      end
    end
  end
end
