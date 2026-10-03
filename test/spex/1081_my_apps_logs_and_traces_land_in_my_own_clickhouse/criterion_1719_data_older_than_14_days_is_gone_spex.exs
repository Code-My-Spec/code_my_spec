defmodule CodeMySpecSpex.Story1081.Criterion1719Spex do
  @moduledoc """
  Story 1081 -- My app's logs and traces land in my own ClickHouse
  Criterion 1719 -- Data older than 14 days is gone.

  Surface: `CodeMySpec.McpServers.Devops.Tools.QueryTelemetry`, driving
  `CodeMySpec.Telemetry`'s retention.
  """

  use CodeMySpecSpex.Case

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
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/servers?env=uat")

        run_console_step(view, :monitoring)
        await_console_step(view, :monitoring)

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
        assert body =~ ~r/no (log|trace)/i or body == "",
               "expected no data older than the 14 day retention window"

        {:ok, context}
      end

      then_ "logs from 13 days ago are returned", context do
        refute context.recent_response.isError,
               "expected the query to succeed: #{inspect(context.recent_response)}"

        body = response_text(context.recent_response)
        refute body == "", "expected data within the retention window to be returned"

        {:ok, context}
      end
    end
  end
end
