defmodule CodeMySpecSpex.Story562.Criterion6494Spex do
  @moduledoc """
  Story 562 — Connected Requirement Graph Across Entities
  Criterion 6494 — Fresh project surfaces only project-chain work as
  actionable.

  Codifies the cross-scope edge gating rule (3ca9979d): on a freshly-
  initialized project whose project chain is wholly unsatisfied — even
  when components and stories already exist in the DB — get_next_requirement
  returns a project-scope requirement at the head and excludes every
  component-scope requirement from the response.

  Surface: get_next_requirement MCP tool. The base topology comes from
  `:context_with_three_children` (bare context + three child components,
  no project-chain artifacts applied).
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Fresh project surfaces only project-chain work as actionable" do
    scenario "the response advertises a project-scope requirement and no component requirements" do
      given_ :context_with_three_children

      when_ "the agent calls get_next_requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
        {:ok, Map.put(context, :response_text, TaskResponseHelpers.response_text(response))}
      end

      then_ "the response advertises a project-scope requirement at the head",
            context do
        assert context.response_text =~ ~s(entity_type=`project`),
               "expected a project-scope requirement at the head; got: #{context.response_text}"

        {:ok, context}
      end

      then_ "the response does not advertise any component-scope requirements",
            context do
        refute context.response_text =~ ~s(entity_type=`component`),
               "expected no component-scope requirements while the project chain is unsatisfied; got: #{context.response_text}"

        {:ok, context}
      end
    end
  end
end
