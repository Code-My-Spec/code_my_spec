defmodule CodeMySpecSpex.Story1116.Criterion1700Spex do
  @moduledoc """
  Story 1116 — Agents can read my deployed app's logs and traces.
  Criterion 1700 — Coder follows a failed request from its trace id.

  Rule 4cda53df: given a trace id, an agent gets the request's span tree
  and every log line emitted during it.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Observability.Tools.GetTrace
  alias CodeMySpecSpex.ClickHouseCassetteHelpers
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A trace id gets its span tree and its logs", criterion: 1700 do
    scenario "a coder follows a failed request by its trace id" do
      given_ "a failed request's span and its error log are both on record", context do
        conn = ClickHouseCassetteHelpers.configure!(context.scope)

        Req.Test.stub(CodeMySpec.Observability.ClickHouseClient, fn plug_conn ->
          {:ok, body, plug_conn} = Plug.Conn.read_body(plug_conn)

          rows =
            ClickHouseCassetteHelpers.pick_for_table(
              body,
              [
                %{
                  "Timestamp" => "t",
                  "SpanId" => "span1",
                  "ParentSpanId" => "",
                  "SpanName" => "GET /app",
                  "SpanKind" => "SERVER",
                  "Duration" => "1900000000",
                  "StatusCode" => "Error",
                  "StatusMessage" => "column does not exist"
                }
              ],
              [%{"Timestamp" => "t", "SeverityText" => "ERROR", "Body" => "Ecto.QueryError", "SpanId" => "span1"}]
            )

          Plug.Conn.send_resp(plug_conn, 200, Enum.map_join(rows, "\n", &Jason.encode!/1))
        end)

        {:ok, Map.put(context, :username, conn.username)}
      end

      when_ "the coder asks for that trace", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, reply, _frame} = GetTrace.execute(%{trace_id: "the-failed-trace"}, frame)

        {:ok, Map.put(context, :reply, reply)}
      end

      then_ "it gets the span and the log line emitted during it", context do
        text = TaskResponseHelpers.response_text(context.reply)
        refute context.reply.isError, "expected a successful trace lookup: #{text}"
        assert text =~ "GET /app"
        assert text =~ "Error"
        assert text =~ "Ecto.QueryError"

        {:ok, context}
      end
    end
  end
end
