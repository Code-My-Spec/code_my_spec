defmodule CodeMySpecSpex.Story1081.Criterion1858Spex do
  @moduledoc """
  Story 1081 -- My app's logs and traces land in my own ClickHouse
  Criterion 1858 -- Read-only login can't write or administer.

  Twin of criterion 1716.

  Surface: `CodeMySpecWeb.ConsoleLive`'s Checks tab, driving the
  `:monitoring` step's own read/write probe.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers
  setup :fake_working_directory
  setup :confirm_new_servers

  spex "Read-only login can't write or administer", criterion: 1858 do
    scenario "an attempt to write or administer is rejected" do
      given_ "Sam is using the read-only telemetry login", context do
        previous = Application.get_env(:code_my_spec, :provisioning_step_opts, [])

        Application.put_env(
          :code_my_spec,
          :provisioning_step_opts,
          Keyword.put(previous, :telemetry_check_probe, fn _opts ->
            %{reachable: true, reads: :ok, writes: :refused}
          end)
        )

        on_exit(fn -> Application.put_env(:code_my_spec, :provisioning_step_opts, previous) end)

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/servers?env=uat")

        run_console_step(view, :monitoring)
        await_console_step(view, :monitoring)

        {:ok, context}
      end

      when_ "Sam attempts to write to or administer the telemetry store", context do
        {:ok, checks_view, _html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/console/resources/servers?env=uat&tab=checks"
          )

        checks_view
        |> LiveViewTest.element("[data-test='run-check'][data-check='monitoring']")
        |> LiveViewTest.render_click()

        {:ok, Map.put(context, :html, render(checks_view))}
      end

      then_ "the action is rejected", context do
        result =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='telemetry-check-result']")

        assert Floki.attribute(result, "data-writes") == ["refused"],
               "expected the write/administer attempt to be rejected"

        {:ok, context}
      end
    end
  end
end
