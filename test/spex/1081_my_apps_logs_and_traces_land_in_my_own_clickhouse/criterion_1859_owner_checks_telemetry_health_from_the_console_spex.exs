defmodule CodeMySpecSpex.Story1081.Criterion1859Spex do
  @moduledoc """
  Story 1081 -- My app's logs and traces land in my own ClickHouse
  Criterion 1859 -- Owner checks telemetry health from the console.

  Twin of criterion 1717, framed as the owner opening the resource.

  Surface: `CodeMySpecWeb.ConsoleLive`'s Checks tab, driving the
  `:telemetry` step's own combined probe.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers
  setup :fake_working_directory
  setup :confirm_new_servers

  spex "Owner checks telemetry health from the console", criterion: 1859 do
    scenario "Sam sees the current health status after checking" do
      given_ "a project has telemetry set up", context do
        previous = Application.get_env(:code_my_spec, :provisioning_step_opts, [])

        Application.put_env(
          :code_my_spec,
          :provisioning_step_opts,
          Keyword.put(previous, :check_probe, fn _opts ->
            %{reachable: true, reads: :ok, writes: :refused}
          end)
        )

        on_exit(fn -> Application.put_env(:code_my_spec, :provisioning_step_opts, previous) end)

        {:ok, view, _html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/console/resources/telemetry?env=uat"
          )

        run_console_step(view, :telemetry)
        await_console_step(view, :telemetry)

        {:ok, context}
      end

      when_ "Sam opens the console's Telemetry resource and checks it", context do
        {:ok, checks_view, _html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/console/resources/telemetry?env=uat&tab=checks"
          )

        checks_view
        |> element("[data-test='run-check'][data-check='telemetry']")
        |> render_click()

        {:ok, Map.put(context, :html, render(checks_view))}
      end

      then_ "Sam sees the current health status", context do
        result =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='telemetry-check-result']")

        assert result != [], "expected a health status to render after checking"

        {:ok, context}
      end
    end
  end
end
