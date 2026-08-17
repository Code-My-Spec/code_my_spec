defmodule CodeMySpecSpex.Story561.Criterion5617Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements
  Criterion 5617 — A requirement that has been satisfied no longer
  appears in subsequent calls.

  Surface: get_next_requirement MCP tool. After syncing a context
  with valid spec content, parent.spec_file is satisfied. The
  response must not advertise a start_task call for that satisfied
  requirement on that specific component.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Satisfied requirement is excluded from actionable" do
    scenario "the response does not advertise the satisfied parent spec_file" do
      given_ :context_with_three_children

      when_ "the agent calls get_next_requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
        {:ok, Map.put(context, :response_text, TaskResponseHelpers.response_text(response))}
      end

      then_ "the tool offered actionable work at all", context do
        # The contrast the refutes need. `get_next_requirement` returning
        # nothing satisfies "this particular requirement is absent" exactly as
        # well as returning a list with it correctly left out.
        assert context.response_text =~ "requirement_name=",
               "expected at least one actionable requirement to be advertised, got:\n" <>
                 context.response_text

        {:ok, context}
      end

      then_ "no start_task call references the parent context's spec_file",
            context do
        parent_id = context.parent_context.id

        signature =
          ~r/requirement_name=`spec_file`,\s*entity_type=`component`,\s*entity_id=`#{parent_id}`/

        refute Regex.match?(signature, context.response_text),
               "expected the parent's satisfied spec_file to be filtered, but found a start_task call for it"

        {:ok, context}
      end
    end
  end
end
