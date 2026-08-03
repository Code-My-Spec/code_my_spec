defmodule CodeMySpecSpex.Story671.Criterion5643Spex do
  @moduledoc """
  Story 671 — Project Configuration Filters the Graph Cleanly
  Criterion 5643 — Each filter applies independently. Disabling
  reviews leaves spec and test nodes untouched.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.GraphAssertions

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Disabling reviews does not affect spec or test nodes" do
    scenario "no review nodes; spec and test nodes appear at normal positions" do
      given_ :context_with_three_children
      given_ :on_configuration_page

      when_ "the engineer disables ONLY require_reviews", context do
        context.config_live
        |> form("[data-test='configuration-form']",
          configuration: %{
            require_specs: true,
            require_reviews: false,
            require_unit_tests: true
          }
        )
        |> render_submit()

        {:ok, context}
      end

      and_ "the engineer renders the requirements graph", context do
        {:ok, _live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/requirements/graph?preload=true")

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "no review_file or review_valid component node appears", context do
        review_nodes =
          context.graph["nodes"]
          |> Enum.filter(fn n ->
            n["attributes"]["entity_type"] == "component" and
              n["attributes"]["name"] in ["review_file", "review_valid"]
          end)

        assert review_nodes == [],
               "expected no review nodes after disabling require_reviews"

        {:ok, context}
      end

      and_ "spec_file and spec_valid still appear for the parent and each child",
           context do
        all_components = [
          context.parent_context,
          context.child_schema,
          context.child_repository,
          context.child_service
        ]

        for comp <- all_components, name <- ["spec_file", "spec_valid"] do
          assert GraphAssertions.find_node(context.graph, "component", comp.id, name),
                 "expected #{comp.module_name} to retain #{name} when only reviews are disabled"
        end

        {:ok, context}
      end

      and_ "test_file, test_spec_alignment, and tests_passing still appear for components that support them",
           context do
        # repo and service use default_graph which has the full test phase.
        # schema lacks test phases by template — exclude it from this assertion.
        for child <- [context.child_repository, context.child_service],
            name <- ["test_file", "test_spec_alignment", "tests_passing"] do
          assert GraphAssertions.find_node(context.graph, "component", child.id, name),
                 "expected #{child.module_name} to retain #{name} when only reviews are disabled"
        end

        {:ok, context}
      end
    end
  end
end
