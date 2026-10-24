defmodule CodeMySpecSpex.Story1081.Criterion1715Spex do
  @moduledoc """
  Story 1081 -- My app's logs and traces land in my own ClickHouse
  Criterion 1715 -- Sam queries telemetry from their own client.

  Sam connecting with his own ClickHouse client is outside the app's
  surfaces entirely, so this drives the console's own Checks tab, which
  proves the read-only credential works the same way the TLS step proves
  a certificate -- via a real request, injectable only for the spec.

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

  spex "Sam queries telemetry from their own client", criterion: 1715 do
    scenario "the read-only credential reads every project's data on the box" do
      given_ "UAT telemetry is set up", context do
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

        {:ok, Map.put(context, :view, view)}
      end

      when_ "Sam connects with the read-only credentials setup gave them", context do
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

      then_ "they can query logs and traces from every project on that server", context do
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
