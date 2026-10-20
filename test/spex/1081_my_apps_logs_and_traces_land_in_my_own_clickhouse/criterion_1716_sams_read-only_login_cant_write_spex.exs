defmodule CodeMySpecSpex.Story1081.Criterion1716Spex do
  @moduledoc """
  Story 1081 -- My app's logs and traces land in my own ClickHouse
  Criterion 1716 -- Sam's read-only login can't write.

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

  spex "Sam's read-only login can't write", criterion: 1716 do
    scenario "ClickHouse refuses an insert or drop from the read-only login" do
      given_ "Sam is connected with the read-only credentials", context do
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

      when_ "they try to insert or drop data", context do
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

      then_ "ClickHouse refuses", context do
        result =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='telemetry-check-result']")

        assert Floki.attribute(result, "data-writes") == ["refused"],
               "expected a write with the read-only login to be refused"

        {:ok, context}
      end
    end
  end
end
