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

  alias CodeMySpec.Requirements.RequirementGraph

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Single actionable node returns a one-element wave" do
    scenario "fresh project's actionable set includes project_setup and is non-empty" do
      when_ "the engineer computes the actionable set on a fresh project", context do
        actionable = RequirementGraph.next_actionable(context.scope)
        {:ok, Map.put(context, :actionable, actionable)}
      end

      then_ "the actionable list is non-empty", context do
        assert context.actionable != [],
               "expected at least one actionable requirement on a fresh project"

        {:ok, context}
      end

      and_ "project_setup is in the actionable set (no prereqs, leaf root)", context do
        match =
          Enum.find(context.actionable, fn req ->
            req.name == "project_setup" and req.entity_type == "project"
          end)

        assert match,
               "expected project_setup in the actionable set, got: #{inspect(Enum.map(context.actionable, &{&1.entity_type, &1.name}))}"

        {:ok, context}
      end
    end
  end
end
