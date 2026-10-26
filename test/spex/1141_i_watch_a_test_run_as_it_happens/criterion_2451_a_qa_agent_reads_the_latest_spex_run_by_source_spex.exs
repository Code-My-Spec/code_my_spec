defmodule CodeMySpecSpex.Story1141.Criterion2451Spex do
  @moduledoc """
  Story 1141 — I watch a test run as it happens.
  Criterion 2451 — A QA agent reads the latest spex run by source.
  """

  use CodeMySpecSpex.Case, async: true

  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A QA agent reads the latest spex run by source", criterion: 2451 do
    scenario "source spex selects the running run on the QA agent's copy" do
      given_ "a spex run is running on the QA agent's working copy", context do
        qa = Fixtures.running_agent(context.scope, role: "qa")
        older = Fixtures.completed_analysis_run(context.scope, "spex")
        current = Fixtures.reporting_analysis_run(context.scope, "spex")
        {:ok, Map.merge(context, %{qa: qa, older_run_id: older.id, run_id: current.id})}
      end

      when_ "the agent calls get_analysis_live with source spex and no run id", context do
        tool_context = %{
          scope: context.scope,
          current_scope: context.scope,
          agent_id: context.qa.id
        }

        {:ok, body} = ToolLibrary.run("get_analysis_live", %{source: "spex"}, tool_context)
        {:ok, Map.put(context, :live_reply, Jason.decode!(body))}
      end

      then_ "it reads that spex run, the latest one in the working copy", context do
        assert context.live_reply["run_id"] == context.run_id
        refute context.live_reply["run_id"] == context.older_run_id
        assert context.live_reply["source"] == "spex"
        assert context.live_reply["status"] == "running"
        {:ok, context}
      end
    end
  end
end
