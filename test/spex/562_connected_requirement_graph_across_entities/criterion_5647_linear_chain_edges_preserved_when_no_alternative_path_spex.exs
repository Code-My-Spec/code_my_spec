defmodule CodeMySpecSpex.Story562.Criterion5647Spex do
  @moduledoc "Child implementation edges survive reduction without retired test gates."
  use CodeMySpecSpex.Case
  import CodeMySpecSpex.GraphGivens
  alias CodeMySpecSpex.GraphAssertions
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Child implementations feed the parent directly" do
    scenario "each child has an indispensable edge to the parent" do
      given_ :context_with_three_children

      when_ "the engineer opens the graph", context do
        {:ok, _view, html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/requirements/graph?preload=true"
          )

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "all child implementation edges are retained", context do
        parent =
          GraphAssertions.node_key("component", context.parent_context.id, "implementation_file")

        for child <- [context.child_schema, context.child_repository, context.child_service] do
          source = GraphAssertions.node_key("component", child.id, "implementation_file")
          assert GraphAssertions.edge?(context.graph, source, parent)
        end

        refute Enum.any?(context.graph["nodes"], &(&1["attributes"]["name"] == "tests_passing"))
        {:ok, context}
      end
    end
  end
end
