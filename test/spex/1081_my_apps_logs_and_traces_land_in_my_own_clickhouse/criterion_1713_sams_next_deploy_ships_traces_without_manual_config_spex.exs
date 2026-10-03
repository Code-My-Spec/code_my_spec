defmodule CodeMySpecSpex.Story1081.Criterion1713Spex do
  @moduledoc """
  Story 1081 -- My app's logs and traces land in my own ClickHouse
  Criterion 1713 -- Sam's next deploy ships traces without manual config.

  Surface: `CodeMySpecWeb.ConsoleLive` on the cloud app, driving the
  `:deploy` step's generated configuration once `:telemetry` has run.
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
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/telemetry?env=uat")

        run_console_step(view, :telemetry)
        await_console_step(view, :telemetry)

        {:ok, Map.put(context, :view, view)}
      end

      when_ "Sam's app is next deployed to UAT", context do
        {:ok, secrets_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/secrets")

        open_secrets_dialog(secrets_view)

        secrets_view
        |> form("[data-test='secret-form']",
          secret: %{key: "SECRET_KEY_BASE", value: "generated-value", environment: "uat"}
        )
        |> render_submit()

        {:ok, deploys_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/deploys")

        deploys_view |> element("[data-test='generate-project']") |> render_click()

        deploys_view
        |> element(
          "[data-test='deploy-row'][data-environment='uat'] [data-test='deploy-environment-form']"
        )
        |> render_submit()

        {:ok, Map.put(context, :deploys_view, deploys_view)}
      end

      then_ "its deploy configuration names the telemetry collector and the app's service name",
            context do
        context.scope.environment
        |> Environments.read_file("config/deploy.yml")
        |> assert_deploy_config_names_telemetry()

        {:ok, context}
      end

      then_ "its traces arrive without Sam editing any file", context do
        html = render(context.deploys_view)

        assert resource_step_state?(html, "deploy", "done"),
               "expected the deploy to complete with no manual telemetry edit required"

        {:ok, context}
      end
    end
  end

  defp assert_deploy_config_names_telemetry({:ok, content}) do
    assert content =~ "telemetry",
           "expected the deploy config to name the telemetry collector"
  end

  defp assert_deploy_config_names_telemetry({:error, reason}) do
    flunk("expected a generated deploy config, got #{inspect(reason)}")
  end
end
