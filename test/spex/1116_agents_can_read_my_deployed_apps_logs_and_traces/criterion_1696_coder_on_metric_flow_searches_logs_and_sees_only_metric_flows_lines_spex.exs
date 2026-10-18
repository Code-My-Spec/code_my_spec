defmodule CodeMySpecSpex.Story1116.Criterion1696Spex do
  @moduledoc """
  Story 1116 — Agents can read my deployed app's logs and traces.
  Criterion 1696 — Coder on metric_flow searches logs and sees only
  metric_flow's lines.

  Rule 4a1643c1: every agent role on the project can read its logs and
  traces. Rule 094d4f4b: an agent sees only its own project's logs and
  traces.

  `query_logs` connects as the calling project's own ClickHouse user —
  never a shared one — so "only this project's lines" is not something
  the tool filters for, it is the only thing the connection can see.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.ClickHouseCassetteHelpers
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A coder searches their own project's deployed logs", criterion: 1696 do
    scenario "metric_flow's coder searches and sees its own lines" do
      given_ "metric_flow has telemetry configured, with a log line on record", context do
        conn = ClickHouseCassetteHelpers.configure!(context.scope)

        ClickHouseCassetteHelpers.stub_rows_for_username(conn.username, [
          %{
            "Timestamp" => "2026-10-02 08:00:00",
            "SeverityText" => "INFO",
            "Body" => "GET /app 200"
          }
        ])

        {:ok, context}
      end

      when_ "the coder searches its logs", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        reply = ToolLibrary.run("query_logs", %{}, %{scope: frame.assigns.current_scope})

        {:ok, Map.put(context, :reply, reply)}
      end

      then_ "it sees its own log line", context do
        assert match?({:ok, _}, context.reply),
               "expected a successful search, got: #{TaskResponseHelpers.response_text(context.reply)}"

        assert TaskResponseHelpers.response_text(context.reply) =~ "GET /app 200"

        {:ok, context}
      end
    end
  end
end
