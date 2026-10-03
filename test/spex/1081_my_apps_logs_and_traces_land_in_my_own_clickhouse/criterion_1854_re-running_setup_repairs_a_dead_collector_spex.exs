defmodule CodeMySpecSpex.Story1081.Criterion1854Spex do
  @moduledoc """
  Story 1081 -- My app's logs and traces land in my own ClickHouse
  Criterion 1854 -- Re-running setup repairs a dead collector.

  Twin of criterion 1712.

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

  spex "Re-running setup repairs a dead collector", criterion: 1854 do
    scenario "a re-run repairs the collector and telemetry flow resumes" do
      given_ "the collector died after a working setup", context do
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

      then_ "setup repairs it and telemetry flow resumes", context do
        assert resource_step_state?(context.html, "monitoring", "done"),
               "expected the re-run to repair the collector and resume telemetry flow"

        {:ok, context}
      end
    end
  end
end
