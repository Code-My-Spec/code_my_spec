defmodule CodeMySpecSpex.Story671.Criterion5632Spex do
  @moduledoc """
  Story 671 — Project Configuration Filters the Graph Cleanly
  Criterion 5632 — With require_reviews at its default true, review_file
  and review_valid nodes appear for context-typed components.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias CodeMySpecSpex.GraphAssertions

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "require_reviews=true (default) keeps review nodes intact" do
    scenario "review_file and review_valid appear for the parent context" do
      given_ :context_with_three_children

      when_ "the engineer renders the requirements graph (no toggles)", context do
        {:ok, _live, html} =
          live(context.conn, "/app/projects/#{context.project.name}/requirements/graph?preload=true")

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "the parent context has review_file and review_valid nodes", context do
        for name <- ["review_file", "review_valid"] do
          node =
            GraphAssertions.find_node(context.graph, "component", context.parent_context.id, name)

          assert node,
                 "expected parent context to have a #{name} node with require_reviews at default true"
        end

        {:ok, context}
      end
    end
  end
end
