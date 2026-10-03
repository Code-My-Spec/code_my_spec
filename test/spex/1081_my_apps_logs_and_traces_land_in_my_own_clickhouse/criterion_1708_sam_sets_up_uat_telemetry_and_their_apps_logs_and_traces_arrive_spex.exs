defmodule CodeMySpecSpex.Story1081.Criterion1708Spex do
  @moduledoc """
  Story 1081 -- My app's logs and traces land in my own ClickHouse
  Criterion 1708 -- Sam sets up UAT telemetry and their app's logs and traces arrive.

  The collector is the `:monitoring` provisioning step -- the key already
  reserved in `Step.keys/0` and grouped under the console's "Servers" card
  by `ResourceGroups`, left unimplemented until this story.

  Surface: `CodeMySpecWeb.ConsoleLive` on the cloud app, driving
  `CodeMySpec.Telemetry` through the `:monitoring` step.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers
  setup :fake_working_directory
  setup :confirm_new_servers

  spex "Sam sets up UAT telemetry and their app's logs and traces arrive", criterion: 1708 do
    scenario "the collector is running and a served request is captured" do
      given_ "Sam's project has a UAT server and a domain", context do
        {:ok, project} = Fixtures.set_project_domain(context.project, "example.app")

        previous = Application.get_env(:code_my_spec, :provisioning_step_opts, [])

        Application.put_env(
          :code_my_spec,
          :provisioning_step_opts,
          Keyword.put(previous, :telemetry_probe, fn _opts -> {:ok, %{logs: 1, traces: 1}} end)
        )

        on_exit(fn -> Application.put_env(:code_my_spec, :provisioning_step_opts, previous) end)

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{project.id}/console/resources/servers?env=uat")

        {:ok, context |> Map.put(:project, project) |> Map.put(:view, view)}
      end

      when_ "Sam runs the telemetry setup step for UAT", context do
        run_console_step(context.view, :monitoring)
        await_console_step(context.view, :monitoring)

        {:ok, context}
      end

      when_ "their app serves a request on UAT", context do
        _response = fetch_site("uat.#{context.project.domain}")

        {:ok, context}
      end

      then_ "that request's log lines and trace are stored in ClickHouse on the UAT server",
            context do
        html = render(context.view)

        resource =
          html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='provisioned-resource'][data-kind='telemetry_collector']")

        assert resource != [],
               "expected the monitoring step to record a telemetry collector resource"

        assert resource_step_state?(html, "monitoring", "done"),
               "expected the monitoring step to be done once the collector is proven"

        {:ok, context}
      end
    end
  end
end
