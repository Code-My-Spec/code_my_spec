defmodule CodeMySpecSpex.Story1081.Criterion1713Spex do
  @moduledoc """
  Story 1081 -- My app's logs and traces land in my own ClickHouse
  Criterion 1713 -- Sam's next deploy ships traces without manual config.

  Surface: `CodeMySpecWeb.ConsoleLive` on the cloud app, driving the
  `:deploy` step's generated configuration once `:monitoring` has run.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpec.Environments

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers
  setup :fake_working_directory
  setup :confirm_new_servers

  spex "Sam's next deploy ships traces without manual config", criterion: 1713 do
    scenario "the generated deploy configuration already names the collector" do
      given_ "UAT telemetry setup completed", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/servers?env=uat")

        run_console_step(view, :monitoring)
        await_console_step(view, :monitoring)

        {:ok, Map.put(context, :view, view)}
      end

      when_ "Sam's app is next deployed to UAT", context do
        run_console_step(context.view, :deploy)
        await_console_step(context.view, :deploy)

        {:ok, context}
      end

      then_ "its deploy configuration names the telemetry collector and the app's service name",
            context do
        case Environments.read_file(context.scope.environment, "config/deploy.yml") do
          {:ok, content} ->
            assert content =~ "telemetry",
                   "expected the deploy config to name the telemetry collector"

          {:error, reason} ->
            flunk("expected a generated deploy config, got #{inspect(reason)}")
        end

        {:ok, context}
      end

      then_ "its traces arrive without Sam editing any file", context do
        html = render(context.view)

        assert resource_step_state?(html, "deploy", "done"),
               "expected the deploy to complete with no manual telemetry edit required"

        {:ok, context}
      end
    end
  end
end
