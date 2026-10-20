defmodule CodeMySpecSpex.Story1081.Criterion1855Spex do
  @moduledoc """
  Story 1081 -- My app's logs and traces land in my own ClickHouse
  Criterion 1855 -- Later deploys ship traces automatically.

  Twin of criterion 1713.

  Surface: `CodeMySpecWeb.ConsoleLive` on the cloud app, driving the
  `:deploy` step once `:telemetry` has run.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers
  setup :fake_working_directory
  setup :confirm_new_servers

  spex "Later deploys ship traces automatically", criterion: 1855 do
    scenario "a later deploy ships traces with no manual telemetry configuration" do
      given_ "telemetry setup has run once for Sam's project", context do
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

        run_console_step(view, :telemetry)
        await_console_step(view, :telemetry)

        {:ok, Map.put(context, :view, view)}
      end

      when_ "Sam deploys a new release", context do
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

        {:ok, Map.put(context, :html, render(deploys_view))}
      end

      then_ "traces ship automatically with no manual telemetry configuration", context do
        assert resource_step_state?(context.html, "deploy", "done"),
               "expected the deploy to ship traces automatically"

        {:ok, context}
      end
    end
  end
end
