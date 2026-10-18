defmodule CodeMySpecSpex.Story1116.Criterion1707Spex do
  @moduledoc """
  Story 1116 — Agents can read my deployed app's logs and traces.
  Criterion 1707 — Coder asks for the slowest requests.

  Rule 34f14a68's other half: the slowest spans, without writing a
  query.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.ClickHouseCassetteHelpers
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The slowest requests, without writing a query", criterion: 1707 do
    scenario "a coder asks for the slowest spans" do
      given_ "one request took far longer than the rest", context do
        conn = ClickHouseCassetteHelpers.configure!(context.scope)

        ClickHouseCassetteHelpers.stub_rows_for_username(conn.username, [
          %{
            "Timestamp" => "t",
            "SpanName" => "Repo.query",
            "Duration" => "1850000000",
            "TraceId" => "slow-one",
            "StatusCode" => "Ok"
          }
        ])

        {:ok, context}
      end

      when_ "the coder asks for the slowest requests", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        reply = ToolLibrary.run("slow_spans", %{}, %{scope: frame.assigns.current_scope})

        {:ok, Map.put(context, :reply, reply)}
      end

      then_ "it sees the slow span and how long it took, with no query written", context do
        text = TaskResponseHelpers.response_text(context.reply)
        assert match?({:ok, _}, context.reply), "expected a successful slow-span read: #{text}"
        assert text =~ "Repo.query"
        assert text =~ "1850ms"

        {:ok, context}
      end
    end
  end
end
