defmodule CodeMySpecSpex.Story561.Criterion5813Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements
  Criterion 5813 — When exactly one node is actionable in the graph
  and no other nodes share its sort key, the wave returned by
  next_actionable contains that single node.

  Surface: get_next_requirement MCP tool. The response advertises
  exactly one start_task signature, with no companion siblings.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Single actionable node returns a one-element wave" do
    scenario "fresh project advertises exactly project_setup with no peers" do
      when_ "the agent calls get_next_requirement on a fresh project", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
        {:ok, Map.put(context, :response_text, TaskResponseHelpers.response_text(response))}
      end

      then_ "the response advertises exactly one start_task signature", context do
        text = context.response_text
        signatures = Regex.scan(~r/start_task[^\n]*requirement_name=/, text)

        assert length(signatures) == 1,
               "expected exactly one start_task signature in the wave, got #{length(signatures)}. Response: #{text}"

        {:ok, context}
      end

      and_ "that signature names project_setup", context do
        assert context.response_text =~ "requirement_name=`project_setup`",
               "expected the lone wave entry to be project_setup. Response: #{context.response_text}"

        {:ok, context}
      end
    end
  end
end
