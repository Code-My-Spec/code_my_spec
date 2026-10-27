defmodule CodeMySpecSpex.Story1141.Criterion2453Spex do
  @moduledoc """
  Story 1141 — I watch a test run as it happens.
  Criterion 2453 — A queued run reads as not reporting yet.
  """

  use CodeMySpecSpex.Case, async: true

  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A queued run reads as not reporting yet", criterion: 2453 do
    scenario "an agent can distinguish a queued run from a streaming run" do
      given_ "an exunit run is queued and has not started", context do
        run = Fixtures.start_analysis_run(context.scope, "exunit")
        {:ok, Map.put(context, :run_id, run.id)}
      end

      when_ "an agent calls get_analysis_live for it", context do
        tool_context = %{scope: context.scope, current_scope: context.scope}

        {:ok, body} =
          ToolLibrary.run("get_analysis_live", %{run_id: context.run_id}, tool_context)

        {:ok, Map.put(context, :live_reply, Jason.decode!(body))}
      end

      then_ "the status is queued and live is no_events", context do
        assert context.live_reply["run_id"] == context.run_id
        assert context.live_reply["status"] == "queued"
        assert context.live_reply["live"] == "no_events"
        {:ok, context}
      end
    end
  end
end
