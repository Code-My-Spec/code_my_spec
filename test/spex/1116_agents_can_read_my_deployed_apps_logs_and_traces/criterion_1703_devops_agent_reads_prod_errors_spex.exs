defmodule CodeMySpecSpex.Story1116.Criterion1703Spex do
  @moduledoc """
  Story 1116 — Agents can read my deployed app's logs and traces.
  Criterion 1703 — Devops agent reads prod errors.

  Rule 08020acd: an agent chooses which environment to read — naming
  "prod" reads prod, not whatever the default would have been. The
  `coding` role carries the devops-flavored tools in this project
  (`ensure_app_running`/`restart_app`/`stop_app` live on `@coding_tools`
  already), so that's the role driving this one.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.ClickHouseCassetteHelpers
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Naming prod reads prod's own telemetry", criterion: 1703 do
    scenario "an agent asks error_summary for the prod environment" do
      given_ "prod and uat have different telemetry configured, and prod has a real error",
             context do
        uat_username =
          ClickHouseCassetteHelpers.configure!(context.scope, environment: "uat").username

        prod_username =
          ClickHouseCassetteHelpers.configure!(context.scope, environment: "prod").username

        ClickHouseCassetteHelpers.stub_rows_by_username(%{
          prod_username => [
            %{"message" => "prod is erroring", "count" => "5", "last_seen" => "t"}
          ],
          uat_username => [%{"message" => "WRONG CONNECTION — this is uat's data, not prod's"}]
        })

        {:ok, context}
      end

      when_ "the agent asks for error_summary in the prod environment", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        reply =
          ToolLibrary.run("error_summary", %{env: "prod"}, %{scope: frame.assigns.current_scope})

        {:ok, Map.put(context, :reply, reply)}
      end

      then_ "it reads prod's own errors, not uat's", context do
        text = TaskResponseHelpers.response_text(context.reply)
        assert match?({:ok, _}, context.reply), "expected a successful prod read: #{text}"
        assert text =~ "prod is erroring"
        refute text =~ "WRONG CONNECTION"

        {:ok, context}
      end
    end
  end
end
