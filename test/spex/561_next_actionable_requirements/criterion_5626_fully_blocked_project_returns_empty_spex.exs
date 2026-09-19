defmodule CodeMySpecSpex.Story561.Criterion5626Spex do
  @moduledoc "A missing child implementation blocks its parent's implementation."
  use CodeMySpecSpex.Case
  import CodeMySpecSpex.GraphGivens
  alias CodeMySpec.Environments
  alias CodeMySpecSpex.GraphAssertions
  alias CodeMySpecSpex.GraphContentFixtures, as: Content
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Only unblocked implementation work is actionable" do
    scenario "child is actionable while its parent waits" do
      given_ :context_with_three_children_in_satisfied_project

      given_ "parent and child code are missing", context do
        for component <- [context.parent_context, context.child_schema] do
          :ok =
            Environments.delete_file(
              context.environment,
              Content.impl_path(component.module_name)
            )
        end

        {:ok, sync(context)}
      end

      when_ "the engineer opens the graph", context do
        {:ok, _view, html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/requirements/graph?preload=true"
          )

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "the child can be built and the parent is blocked", context do
        nodes = context.graph["nodes"]

        child =
          Enum.find(
            nodes,
            &(&1["attributes"]["entity_id"] == context.child_schema.id and
                &1["attributes"]["name"] == "implementation_file")
          )

        parent =
          Enum.find(
            nodes,
            &(&1["attributes"]["entity_id"] == context.parent_context.id and
                &1["attributes"]["name"] == "implementation_file")
          )

        assert child && parent
        assert child["attributes"]["color"] == "#f5f5f7"
        refute parent["attributes"]["color"] == "#f5f5f7"
        {:ok, context}
      end
    end
  end
end
