defmodule CodeMySpecSpex.Story1116.Criterion1701Spex do
  @moduledoc """
  Story 1116 — Agents can read my deployed app's logs and traces.
  Criterion 1701 — Coder asks for a trace that doesn't exist.

  Rule 4cda53df's other half: a trace id nothing emitted is reported as
  not found, not as an empty success a reader might mistake for "the
  request had no spans".
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Observability.Tools.GetTrace
  alias CodeMySpecSpex.ClickHouseCassetteHelpers
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A trace id that never emitted anything is reported missing", criterion: 1701 do
    scenario "a coder asks for a trace id nothing wrote" do
      given_ "telemetry is configured, and nothing carries the trace id about to be asked for",
             context do
        conn = ClickHouseCassetteHelpers.configure!(context.scope)
        ClickHouseCassetteHelpers.stub_rows_for_username(conn.username, [])

        {:ok, context}
      end

      when_ "the coder asks for that trace id", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, reply, _frame} = GetTrace.execute(%{trace_id: "never-happened"}, frame)

        {:ok, Map.put(context, :reply, reply)}
      end

      then_ "it is told the trace was not found, not handed an empty success", context do
        assert context.reply.isError
        assert TaskResponseHelpers.response_text(context.reply) =~ "never-happened"

        {:ok, context}
      end
    end
  end
end
