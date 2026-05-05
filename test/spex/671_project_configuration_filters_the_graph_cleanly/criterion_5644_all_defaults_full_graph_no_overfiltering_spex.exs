defmodule CodeMySpecSpex.Story671.Criterion5644Spex do
  @moduledoc """
  Story 671 — Project Configuration Filters the Graph Cleanly
  Criterion 5644 — All three flags at default true produces the full
  graph with no over-filtering: spec_file, spec_valid, review_file,
  review_valid, test_file, test_spec_alignment, implementation_file,
  and tests_passing all appear at their template positions.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias CodeMySpecSpex.GraphAssertions

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Default config (all true) produces the full unfiltered graph" do
    scenario "every artifact node appears at its expected component" do
      given_ :context_with_three_children

      when_ "the engineer renders the requirements graph (no toggles)", context do
        {:ok, _live, html} =
          live(context.conn, "/projects/#{context.project.name}/requirements/graph?preload=true")

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "the parent context has the full context_graph node set",
            context do
        parent_names = [
          "spec_file",
          "spec_valid",
          "review_file",
          "review_valid",
          "implementation_file",
          "test_file",
          "test_spec_alignment",
          "tests_passing"
        ]

        for name <- parent_names do
          assert GraphAssertions.find_node(
                   context.graph,
                   "component",
                   context.parent_context.id,
                   name
                 ),
                 "expected parent context to have #{name} node at default config"
        end

        {:ok, context}
      end

      and_ "the repository and service children have full default_graph nodes",
           context do
        # Schema uses schema_graph (no test/review nodes by template).
        # Repository and service use default_graph which includes the full
        # spec → test → impl → tests_passing chain.
        full_chain = [
          "spec_file",
          "spec_valid",
          "test_file",
          "test_spec_alignment",
          "implementation_file",
          "tests_passing"
        ]

        for child <- [context.child_repository, context.child_service], name <- full_chain do
          assert GraphAssertions.find_node(context.graph, "component", child.id, name),
                 "expected child #{child.module_name} (#{child.type}) to have #{name} node at default config"
        end

        {:ok, context}
      end

      and_ "the schema child has its template's spec/impl chain", context do
        schema_chain = ["spec_file", "spec_valid", "implementation_file"]

        for name <- schema_chain do
          assert GraphAssertions.find_node(
                   context.graph,
                   "component",
                   context.child_schema.id,
                   name
                 ),
                 "expected child schema #{context.child_schema.module_name} to have #{name} node at default config"
        end

        {:ok, context}
      end
    end
  end
end
