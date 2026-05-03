defmodule CodeMySpecSpex.Story561.Criterion5817Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements
  Criterion 5817 — All done: when every requirement in the graph is
  satisfied, the response declares completion rather than returning
  empty or a stale wave.

  Surface: get_next_requirement MCP tool. The response includes the
  documented all-satisfied marker text, distinguishable from the
  sync-required and actionable-wave responses.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "All done when every requirement is satisfied" do
    scenario "the fully-satisfied project response advertises completion" do
      given_ :fully_satisfied_project

      when_ "the agent calls get_next_requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
        {:ok, Map.put(context, :response_text, TaskResponseHelpers.response_text(response))}
      end

      then_ "the response declares all requirements satisfied, not a start_task call",
            context do
        text = context.response_text

        assert text =~ ~r/all\s+requirements\s+satisfied/i,
               "expected the all-done marker in the response. Got: #{text}"

        refute text =~ "start_task",
               "no start_task signatures should appear when the project is fully satisfied. Response: #{text}"

        {:ok, context}
      end
    end
  end
end
