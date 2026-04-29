defmodule CodeMySpecSpex.Story561.Criterion5614Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements
  Criterion 5614 — A requirement missing any one of the three
  conditions (satisfied_by present, unsatisfied, prereqs satisfied)
  is excluded from the actionable list.

  Surface: get_next_requirement MCP tool. We verify negatively — the
  response must not advertise satisfied requirements (already-done
  spec_file on the parent) or blocked requirements (deep nodes whose
  upstream isn't ready yet).
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Requirements missing any of the three conditions are excluded" do
    scenario "satisfied requirements and blocked deep requirements do not appear" do
      given_ :context_with_three_children

      when_ "the agent calls get_next_requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
        {:ok, Map.put(context, :response_text, TaskResponseHelpers.response_text(response))}
      end

      then_ "no satisfied requirement is advertised as a start_task call",
            context do
        # Reservations.spec_file is satisfied (file written + valid). It must
        # not appear in the actionable list as a start_task target — verify
        # by checking that the call signature for that specific
        # (entity, requirement_name) pair is absent.
        parent_id = context.parent_context.id
        signature = "entity_id=`#{parent_id}`"
        spec_file_for_parent_pattern = ~r/requirement_name=`spec_file`,\s*entity_type=`component`,\s*#{Regex.escape(signature)}/

        refute Regex.match?(spec_file_for_parent_pattern, context.response_text),
               "expected the parent's satisfied spec_file to be excluded from actionable, but found it"

        {:ok, context}
      end

      and_ "no blocked deep requirement is advertised before its prereq is met",
           context do
        # tests_passing on the parent is multi-hop blocked — its prereq chain
        # extends through test_spec_alignment, test_file, implementation_file,
        # and so on. None of these should be the head action item with a
        # fresh topology where only spec_file/spec_valid are satisfied.
        refute context.response_text =~ "requirement_name=`tests_passing`",
               "expected blocked tests_passing to be excluded from the actionable list head"

        {:ok, context}
      end
    end
  end
end
