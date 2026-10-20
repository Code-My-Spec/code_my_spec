defmodule CodeMySpecSpex.Story1081.Criterion1851Spex do
  @moduledoc """
  Story 1081 -- My app's logs and traces land in my own ClickHouse
  Criterion 1851 -- Setup collects logs and traces into ClickHouse.

  Twin of criterion 1708, without the explicit "app serves a request"
  step -- setup itself is the claim here.

  Surface: `CodeMySpecWeb.ConsoleLive` on the cloud app, driving
  `CodeMySpec.Telemetry` through the `:telemetry` step.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers
  setup :fake_working_directory
  setup :confirm_new_servers

  spex "Setup collects logs and traces into ClickHouse", criterion: 1851 do
    scenario "the app's logs and traces land in ClickHouse on Sam's own server" do
      given_ "Sam has a provisioned server for an environment", context do
        previous = Application.get_env(:code_my_spec, :provisioning_step_opts, [])

        Application.put_env(
          :code_my_spec,
          :provisioning_step_opts,
          Keyword.put(previous, :run_probe, fn _opts -> {:ok, %{logs: 1, traces: 1}} end)
        )

        on_exit(fn -> Application.put_env(:code_my_spec, :provisioning_step_opts, previous) end)

        {:ok, servers_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/servers")

        run_console_step(servers_view, :server)
        await_console_step(servers_view, :server)

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

      then_ "the app's logs and traces land in ClickHouse on Sam's own server", context do
        resource =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='provisioned-resource'][data-kind='telemetry_collector']")

        assert resource != [],
               "expected setup to record a telemetry collector proving data landed"

        assert resource_step_state?(context.html, "telemetry", "done"),
               "expected the telemetry step to be done"

        {:ok, context}
      end
    end
  end
end
