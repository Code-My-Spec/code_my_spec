defmodule CodeMySpecSpex.Story1141.Criterion2455Spex do
  @moduledoc """
  Story 1141 — I watch a test run as it happens.
  Criterion 2455 — A run with no live record points the agent to its output.
  """

  use CodeMySpecSpex.Case, async: true

  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A run with no live record points the agent to its output", criterion: 2455 do
    scenario "the live tool identifies the missing record and names the output tool" do
      given_ "an analysis run that has no live record retained", context do
        run = Fixtures.completed_analysis_run(context.scope, "exunit")
        {:ok, Map.put(context, :run_id, run.id)}
      end

      when_ "an agent calls get_analysis_live for it", context do
        tool_context = %{scope: context.scope, current_scope: context.scope}

        {:ok, body} =
          ToolLibrary.run("get_analysis_live", %{run_id: context.run_id}, tool_context)

        {:ok, Map.put(context, :live_reply, Jason.decode!(body))}
      end

      then_ "live is not_retained and the agent is told to read get_analysis_output instead",
            context do
        assert context.live_reply["run_id"] == context.run_id
        assert context.live_reply["live"] == "not_retained"
        assert inspect(context.live_reply) =~ "get_analysis_output"
        {:ok, context}
      end
    end
  end
end
