defmodule CodeMySpecSpex.Story1116.Criterion1704Spex do
  @moduledoc """
  Story 1116 — Agents can read my deployed app's logs and traces.
  Criterion 1704 — Coder searches without naming an environment and
  gets UAT.

  Rule 08020acd: an agent chooses which environment to read, UAT by
  default.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.ClickHouseCassetteHelpers
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "No environment named still means uat", criterion: 1704 do
    scenario "the coder searches without naming env" do
      given_ "uat and prod have different telemetry configured, each with its own line",
             context do
        uat_username =
          ClickHouseCassetteHelpers.configure!(context.scope, environment: "uat").username

        prod_username =
          ClickHouseCassetteHelpers.configure!(context.scope, environment: "prod").username

        ClickHouseCassetteHelpers.stub_rows_by_username(%{
          uat_username => [
            %{"Timestamp" => "t", "SeverityText" => "INFO", "Body" => "uat's own line"}
          ],
          prod_username => [%{"Body" => "WRONG CONNECTION — prod's data, not uat's"}]
        })

        {:ok, context}
      end

      when_ "the coder searches logs without naming an environment", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        reply =
          ToolLibrary.run(
            "query_logs",
            %{},
            Map.put(frame.assigns, :scope, frame.assigns.current_scope)
          )

        {:ok, Map.put(context, :reply, reply)}
      end

      then_ "it read uat, not prod", context do
        text = TaskResponseHelpers.response_text(context.reply)
        assert match?({:ok, _}, context.reply), "expected a successful uat read: #{text}"
        assert text =~ "uat's own line"
        refute text =~ "WRONG CONNECTION"

        {:ok, context}
      end
    end
  end
end
