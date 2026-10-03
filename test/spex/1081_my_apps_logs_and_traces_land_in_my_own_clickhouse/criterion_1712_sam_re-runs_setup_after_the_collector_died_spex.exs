defmodule CodeMySpecSpex.Story1081.Criterion1712Spex do
  @moduledoc """
  Story 1081 -- My app's logs and traces land in my own ClickHouse
  Criterion 1712 -- Sam re-runs setup after the collector died.

  `first_then/2` stages the step's own check to report the collector down
  on its first call (the dead state this scenario starts from) and
  recovered on its second (what the re-run proves).

  Surface: `CodeMySpecWeb.ConsoleLive` on the cloud app, driving the
  `:monitoring` step's repair-on-rerun behavior.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers
  setup :fake_working_directory
  setup :confirm_new_servers

  spex "Sam re-runs setup after the collector died", criterion: 1712 do
    scenario "re-running brings the collector back and traces resume" do
      given_ "UAT telemetry is set up but its collector container has stopped", context do
        previous = Application.get_env(:code_my_spec, :provisioning_step_opts, [])

        probe =
          first_then(
            fn -> {:error, "the telemetry collector is not running"} end,
            fn -> {:ok, %{logs: 1, traces: 1}} end
          )

        Application.put_env(
          :code_my_spec,
          :provisioning_step_opts,
          Keyword.put(previous, :telemetry_probe, probe)
        )

        on_exit(fn -> Application.put_env(:code_my_spec, :provisioning_step_opts, previous) end)

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/servers?env=uat")

        run_console_step(view, :monitoring)

        {:ok, Map.put(context, :view, view)}
      end

      when_ "Sam re-runs setup", context do
        run_console_step(context.view, :monitoring)
        await_console_step(context.view, :monitoring)

        {:ok, Map.put(context, :html, render(context.view))}
      end

      then_ "the collector is running again and new traces arrive", context do
        assert resource_step_state?(context.html, "monitoring", "done"),
               "expected the re-run to repair the collector rather than stay errored"

        {:ok, context}
      end
    end
  end
end
