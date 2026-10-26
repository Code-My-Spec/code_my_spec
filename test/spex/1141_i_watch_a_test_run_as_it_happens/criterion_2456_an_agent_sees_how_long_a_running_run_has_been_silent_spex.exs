defmodule CodeMySpecSpex.Story1141.Criterion2456Spex do
  @moduledoc """
  Story 1141 — I watch a test run as it happens.
  Criterion 2456 — An agent sees how long a running run has been silent.
  """

  use CodeMySpecSpex.Case, async: true

  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An agent sees how long a running run has been silent", criterion: 2456 do
    scenario "the tool reports the age of the last streaming event" do
      given_ "an exunit run is streaming", context do
        run = Fixtures.silent_live_analysis_run(context.scope, "exunit", 300)
        {:ok, Map.put(context, :run_id, run.id)}
      end

      given_ "its last event arrived about 5 minutes ago", context do
        {:ok, context}
      end

      when_ "an agent calls get_analysis_live for it", context do
        tool_context = %{scope: context.scope, current_scope: context.scope}

        {:ok, body} =
          ToolLibrary.run("get_analysis_live", %{run_id: context.run_id}, tool_context)

        {:ok, Map.put(context, :live_reply, Jason.decode!(body))}
      end

      then_ "seconds_since_event is about 300", context do
        assert context.live_reply["run_id"] == context.run_id
        assert context.live_reply["status"] == "running"
        assert context.live_reply["live"] == "streaming"
        assert context.live_reply["seconds_since_event"] in 295..305
        {:ok, context}
      end
    end
  end
end
