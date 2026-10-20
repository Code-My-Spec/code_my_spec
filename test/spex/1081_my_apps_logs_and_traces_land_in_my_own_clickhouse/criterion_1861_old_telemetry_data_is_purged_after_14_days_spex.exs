defmodule CodeMySpecSpex.Story1081.Criterion1861Spex do
  @moduledoc """
  Story 1081 -- My app's logs and traces land in my own ClickHouse
  Criterion 1861 -- Old telemetry data is purged after 14 days.

  Twin of criterion 1719, framed as the retention policy itself rather
  than a query against it. Modeled the way `Backups.retention_days/1`
  is: the policy is installed as part of setup, before any data lands,
  and recorded as its own resource so it can be read back.

  Surface: `CodeMySpecWeb.ConsoleLive` on the cloud app, driving the
  `:telemetry` step's retention policy.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers
  setup :fake_working_directory
  setup :confirm_new_servers

  spex "Old telemetry data is purged after 14 days", criterion: 1861 do
    scenario "the retention policy drops data older than 14 days automatically" do
      given_ "telemetry data exists that is older than 14 days", context do
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

      when_ "the retention policy runs", context do
        run_console_step(context.view, :telemetry)
        await_console_step(context.view, :telemetry)

        {:ok, Map.put(context, :html, render(context.view))}
      end

      then_ "that data is dropped automatically", context do
        resource =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='provisioned-resource'][data-kind='telemetry_retention']")

        assert resource != [],
               "expected setup to install a retention policy that purges data automatically"

        assert Floki.attribute(resource, "data-identifier") == ["14"],
               "expected the retention policy to keep 14 days"

        {:ok, context}
      end
    end
  end
end
