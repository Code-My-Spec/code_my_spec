defmodule CodeMySpecSpex.Story1116.Criterion1698Spex do
  @moduledoc """
  Story 1116 — Agents can read my deployed app's logs and traces.
  Criterion 1698 — Coder searches a busy hour and is told the result was
  cut off.

  Rule fb40bcc5: every query has a time window and a row cap, and a
  capped result says it was truncated.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Observability.Tools.QueryLogs
  alias CodeMySpecSpex.ClickHouseCassetteHelpers
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A capped search says it was cut off", criterion: 1698 do
    scenario "a busy hour returns more lines than the row cap" do
      given_ "telemetry is configured and a busy hour has more lines than the cap", context do
        conn = ClickHouseCassetteHelpers.configure!(context.scope)

        rows = for n <- 1..3, do: %{"Timestamp" => "t", "SeverityText" => "INFO", "Body" => "line #{n}"}
        ClickHouseCassetteHelpers.stub_rows_for_username(conn.username, rows)

        {:ok, context}
      end

      when_ "the coder searches with a row cap smaller than what happened", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, reply, _frame} = QueryLogs.execute(%{limit: 2}, frame)

        {:ok, Map.put(context, :reply, reply)}
      end

      then_ "it is told the result was cut off, trimmed to the cap", context do
        text = TaskResponseHelpers.response_text(context.reply)
        refute context.reply.isError, "expected a successful, truncated search: #{text}"
        assert text =~ "truncated" or text =~ "cut off" or text =~ "narrow"
        assert text =~ "2 log line(s)"

        {:ok, context}
      end
    end
  end
end
