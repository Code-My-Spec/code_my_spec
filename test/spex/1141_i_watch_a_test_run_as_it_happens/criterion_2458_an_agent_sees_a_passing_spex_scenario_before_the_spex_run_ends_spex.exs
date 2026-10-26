defmodule CodeMySpecSpex.Story1141.Criterion2458Spex do
  @moduledoc """
  Story 1141 — I watch a test run as it happens.
  Criterion 2458 — An agent sees a passing spex scenario before the spex run ends.
  """

  use CodeMySpecSpex.Case, async: true

  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An agent sees a passing spex scenario before the spex run ends", criterion: 2458 do
    scenario "the first passing scenario is counted in a running one-file spex run" do
      given_ "a spex run of one spex file is running", context do
        path = "test/spex/sample_spex.exs"
        scenario = "the first scenario passes"
        run = Fixtures.streaming_spex_scenario(context.scope, path, scenario)
        {:ok, Map.merge(context, %{run_id: run.id, path: path, scenario: scenario})}
      end

      given_ "its first scenario has passed", context do
        {:ok, context}
      end

      when_ "an agent calls get_analysis_live for it", context do
        tool_context = %{scope: context.scope, current_scope: context.scope}

        {:ok, body} =
          ToolLibrary.run("get_analysis_live", %{run_id: context.run_id}, tool_context)

        {:ok, Map.put(context, :live_reply, Jason.decode!(body))}
      end

      then_ "live is streaming and the passing scenario is counted before the run ends",
            context do
        assert context.live_reply["run_id"] == context.run_id
        assert context.live_reply["source"] == "spex"
        assert context.live_reply["status"] == "running"
        assert context.live_reply["live"] == "streaming"
        assert context.live_reply["tests"]["passed"] == 1
        assert context.path in context.live_reply["running_files"]
        {:ok, context}
      end
    end
  end
end
