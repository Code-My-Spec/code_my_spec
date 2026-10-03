defmodule CodeMySpecSpex.Story1081.Criterion1719Spex do
  @moduledoc """
  Story 1081 -- My app's logs and traces land in my own ClickHouse
  Criterion 1719 -- Data older than 14 days is gone.

  The retention window itself (`CodeMySpec.Telemetry.retention_days/0`) is
  the fact under test, not a live ClickHouse TTL -- the staged probe
  answers by that same window, the way `CodeMySpecSpex.Case.stage_certificate/1`
  answers TLS reachability without a live host.

  Surface: `CodeMySpec.McpServers.Devops.Tools.QueryTelemetry`, driving
  `CodeMySpec.Telemetry`'s retention.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Devops.Tools.QueryTelemetry

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers
  setup :fake_working_directory
  setup :confirm_new_servers

  spex "Data older than 14 days is gone", criterion: 1719 do
    scenario "a query past the retention window returns nothing, a query inside it does" do
      given_ "UAT telemetry has been collecting for 20 days", context do
        previous = Application.get_env(:code_my_spec, :provisioning_step_opts, [])

        Application.put_env(
          :code_my_spec,
          :provisioning_step_opts,
          Keyword.merge(previous,
            run_probe: fn _opts -> {:ok, %{logs: 1, traces: 1}} end,
            query_probe: &retention_query_probe/1
          )
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

        {:ok, context}
      end

      when_ "Sam queries logs from 15 days ago", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          QueryTelemetry.execute(%{environment: "uat", since_days: 15}, frame)

        {:ok, Map.put(context, :old_response, response)}
      end

      when_ "Sam queries logs from 13 days ago", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          QueryTelemetry.execute(%{environment: "uat", since_days: 13}, frame)

        {:ok, Map.put(context, :recent_response, response)}
      end

      then_ "none are returned from 15 days ago", context do
        refute context.old_response.isError,
               "expected the query to succeed: #{inspect(context.old_response)}"

        body = response_text(context.old_response)
        assert body =~ "logs: 0", "expected no data older than the 14 day retention window"

        {:ok, context}
      end

      then_ "logs from 13 days ago are returned", context do
        refute context.recent_response.isError,
               "expected the query to succeed: #{inspect(context.recent_response)}"

        body = response_text(context.recent_response)
        assert body =~ "logs: 1", "expected data within the retention window to be returned"

        {:ok, context}
      end
    end
  end

  defp retention_query_probe(opts) do
    opts
    |> Keyword.fetch!(:since_days)
    |> Kernel.>=(CodeMySpec.Telemetry.retention_days())
    |> retention_result()
  end

  defp retention_result(true), do: {:ok, %{logs: 0, traces: 0}}
  defp retention_result(false), do: {:ok, %{logs: 1, traces: 1}}
end
