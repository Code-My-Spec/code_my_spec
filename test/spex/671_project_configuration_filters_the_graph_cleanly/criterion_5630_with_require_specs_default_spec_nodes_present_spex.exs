defmodule CodeMySpecSpex.Story671.Criterion5630Spex do
  @moduledoc """
  Story 671 — Project Configuration Filters the Graph Cleanly
  Criterion 5630 — With require_specs at its default true, spec_file
  and spec_valid nodes appear for the parent and for each child.

  Anchors the test that the filter does not silently remove specs
  when configured to require them — i.e., the default config produces
  the full spec phase.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias CodeMySpecSpex.GraphAssertions

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "require_specs=true (default) keeps spec nodes intact" do
    scenario "spec_file and spec_valid appear for the parent and every child" do
      given_ :context_with_three_children

      when_ "the engineer renders the requirements graph (no toggles)", context do
        {:ok, _live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/requirements/graph?preload=true")

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "the parent context has spec_file and spec_valid nodes", context do
        for name <- ["spec_file", "spec_valid"] do
          node =
            GraphAssertions.find_node(context.graph, "component", context.parent_context.id, name)

          assert node,
                 "expected parent context to have a #{name} node with require_specs at default true"
        end

        {:ok, context}
      end

      and_ "each child component has spec_file and spec_valid nodes", context do
        children = [context.child_schema, context.child_repository, context.child_service]

        for child <- children, name <- ["spec_file", "spec_valid"] do
          node = GraphAssertions.find_node(context.graph, "component", child.id, name)

          assert node,
                 "expected child #{child.module_name} to have a #{name} node with require_specs at default true"
        end

        {:ok, context}
      end
    end
  end
end
