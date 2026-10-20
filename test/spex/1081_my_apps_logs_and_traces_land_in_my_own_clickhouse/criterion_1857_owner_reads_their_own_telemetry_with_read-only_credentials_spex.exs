defmodule CodeMySpecSpex.Story1081.Criterion1857Spex do
  @moduledoc """
  Story 1081 -- My app's logs and traces land in my own ClickHouse
  Criterion 1857 -- Owner reads their own telemetry with read-only credentials.

  Twin of criterion 1715.

  Surface: `CodeMySpecWeb.ConsoleLive`'s Checks tab, driving the
  `:telemetry` step's own read/write probe.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers
  setup :fake_working_directory
  setup :confirm_new_servers

  spex "Owner reads their own telemetry with read-only credentials", criterion: 1857 do
    scenario "Sam sees all telemetry on his server with the read-only login" do
      given_ "Sam has the project's read-only telemetry credentials", context do
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

      when_ "Sam queries telemetry from his own client", context do
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

      then_ "Sam sees all telemetry on their server", context do
        result =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='telemetry-check-result']")

        assert Floki.attribute(result, "data-reads") == ["ok"],
               "expected the read-only credential to read successfully"

        {:ok, context}
      end
    end
  end
end
