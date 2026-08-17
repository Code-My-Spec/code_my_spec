defmodule CodeMySpecSpex.Story78.Criterion5573Spex do
  @moduledoc """
  Story 78 — Context Design Review
  Criterion 5573 — Leaf component types never receive a review task.

  Surface: `list_requirements` MCP tool. The graph template registry only
  stamps `review_file` / `review_valid` nodes for context-typed components.
  A leaf component (e.g. schema) instantiates a graph with no review nodes
  at all — the agent never gets routed into a context-design review for
  something that has no children to review.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.ListRequirements
  alias CodeMySpecSpex.ComponentHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Context Design Review" do
    scenario "Leaf component types never receive a review task" do
      given_ "a leaf schema Component exists in the project", context do
        component =
          ComponentHelpers.create(context.scope,
            type: "schema",
            module_name: "Story78.LeafSchema",
            name: "Story78 LeafSchema"
          )

        {:ok, Map.put(context, :component, component)}
      end

      when_ "the agent calls list_requirements", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} = ListRequirements.execute(%{}, frame)

        {:ok, Map.put(context, :response_text, response_text(response))}
      end

      then_ "the schema component appears in the requirements list", context do
        assert context.response_text =~ "Component: Story78.LeafSchema",
               "expected the leaf component to be present so we know the graph instantiated something for it"

        {:ok, context}
      end

      and_ "no review_file or review_valid requirement is stamped for it", context do
        refute context.response_text =~ "**review_file**",
               "expected leaf components to have no review_file node — review is only for contexts"

        refute context.response_text =~ "**review_valid**",
               "expected leaf components to have no review_valid node — review is only for contexts"

        {:ok, context}
      end
    end
  end
end
