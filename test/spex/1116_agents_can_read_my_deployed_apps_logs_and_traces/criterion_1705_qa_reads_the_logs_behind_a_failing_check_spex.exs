defmodule CodeMySpecSpex.Story1116.Criterion1705Spex do
  @moduledoc """
  Story 1116 — Agents can read my deployed app's logs and traces.
  Criterion 1705 — QA reads the logs behind a failing check.

  Rule 4a1643c1: every agent role on the project can read its logs and
  traces — QA included, not only coding. `query_logs` is on `@qa_tools`.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.ClickHouseCassetteHelpers
  alias CodeMySpec.McpServers.Observability.Tools.QueryLogs
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "QA can read the logs behind a check it is running", criterion: 1705 do
    scenario "QA searches for an error while investigating a failing check" do
      given_ "the deployed app logged an error matching what QA just saw fail", context do
        conn = ClickHouseCassetteHelpers.configure!(context.scope)

        ClickHouseCassetteHelpers.stub_rows_for_username(conn.username, [
          %{
            "Timestamp" => "2026-10-02 08:00:00",
            "SeverityText" => "ERROR",
            "Body" => "500 rendering /app/overview"
          }
        ])

        {:ok, context}
      end

      when_ "QA searches the logs for errors", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, reply, _frame} = QueryLogs.execute(%{level: "ERROR"}, frame)

        {:ok, Map.put(context, :reply, reply)}
      end

      then_ "QA sees the error line behind the failing check", context do
        text = TaskResponseHelpers.response_text(context.reply)
        refute context.reply.isError, "expected QA's search to succeed: #{text}"
        assert text =~ "500 rendering /app/overview"

        {:ok, context}
      end
    end
  end
end
