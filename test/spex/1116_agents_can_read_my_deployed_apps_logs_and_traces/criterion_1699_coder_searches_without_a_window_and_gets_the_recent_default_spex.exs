defmodule CodeMySpecSpex.Story1116.Criterion1699Spex do
  @moduledoc """
  Story 1116 — Agents can read my deployed app's logs and traces.
  Criterion 1699 — Coder searches without a window and gets the recent
  default.

  Rule fb40bcc5: every query has a time window, even an unnamed one —
  there is no "everything, forever" mode.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.ClickHouseCassetteHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "No window named still means a bounded, recent window", criterion: 1699 do
    scenario "the coder searches without naming since/until" do
      given_ "telemetry is configured, and the client records the query it receives", context do
        conn = ClickHouseCassetteHelpers.configure!(context.scope)
        capture = ClickHouseCassetteHelpers.stub_and_capture(conn.username)

        {:ok, Map.put(context, :capture, capture)}
      end

      when_ "the coder searches with no since/until named", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        reply = ToolLibrary.run("query_logs", %{}, %{scope: frame.assigns.current_scope})

        {:ok, Map.put(context, :reply, reply)}
      end

      then_ "the query it actually ran still carried a bounded, recent window", context do
        assert match?({:ok, _}, context.reply)

        {body, params} = ClickHouseCassetteHelpers.captured_request(context.capture)
        assert body =~ "Timestamp >= {since:DateTime64}"
        assert body =~ "Timestamp <= {until:DateTime64}"
        assert is_binary(params["param_since"])
        assert is_binary(params["param_until"])

        {:ok, context}
      end
    end
  end
end
