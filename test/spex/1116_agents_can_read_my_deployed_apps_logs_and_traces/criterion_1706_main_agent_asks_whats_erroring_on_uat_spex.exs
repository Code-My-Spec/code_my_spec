defmodule CodeMySpecSpex.Story1116.Criterion1706Spex do
  @moduledoc """
  Story 1116 — Agents can read my deployed app's logs and traces.
  Criterion 1706 — Main agent asks what's erroring on UAT.

  Rule 34f14a68: an agent can see what's going wrong without writing a
  query — errors grouped by message, and the slowest spans. Main carries
  every tool (`RoleProfile.tools(:main) == :all`), so this is the same
  `error_summary` call, just from the role that never needed a grant.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.ClickHouseCassetteHelpers
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Main can ask what's erroring without writing a query", criterion: 1706 do
    scenario "main asks error_summary for uat" do
      given_ "uat has two different error messages logged more than once", context do
        conn = ClickHouseCassetteHelpers.configure!(context.scope)

        ClickHouseCassetteHelpers.stub_rows_for_username(conn.username, [
          %{"message" => "500 rendering /app/overview", "count" => "4", "last_seen" => "t"}
        ])

        {:ok, context}
      end

      when_ "main asks what's erroring on uat", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        reply =
          ToolLibrary.run(
            "error_summary",
            %{},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, Map.put(context, :reply, reply)}
      end

      then_ "it sees the error grouped with its count, with no query written", context do
        text = TaskResponseHelpers.response_text(context.reply)
        assert match?({:ok, _}, context.reply), "expected a successful summary: #{text}"
        assert text =~ "4x"
        assert text =~ "500 rendering /app/overview"

        {:ok, context}
      end
    end
  end
end
