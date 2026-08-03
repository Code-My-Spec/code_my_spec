defmodule CodeMySpecSpex.Story671.Criterion5634Spex do
  @moduledoc """
  Story 671 — Project Configuration Filters the Graph Cleanly
  Criterion 5634 — With require_unit_tests at its default true, test
  nodes appear for the components that support them and BDD-related
  nodes are present regardless of the unit-tests flag (the default
  baseline that 5633's "false" branch is compared against).
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias CodeMySpecSpex.GraphAssertions
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "require_unit_tests=true (default) keeps test + BDD nodes" do
    scenario "test_* nodes for repo/service; BDD story+project nodes intact" do
      given_ :context_with_three_children

      and_ "a story is linked to a child component", context do
        story =
          StoryHelpers.create_and_link(context.scope, context.child_repository.module_name,
            title: "Reservations user story",
            description: "A story for the BDD-survival test",
            acceptance_criteria: ["Repository works"]
          )

        {:ok, Map.put(context, :story, story)}
      end

      when_ "the engineer renders the requirements graph (no toggles)", context do
        {:ok, _live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/requirements/graph?preload=true")

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "components that support unit tests have their test nodes",
            context do
        # Schema templates don't include test_file/test_spec_alignment/tests_passing,
        # so we only assert on the components that DO support them: repo + service.
        for child <- [context.child_repository, context.child_service],
            name <- ["test_file", "test_spec_alignment", "tests_passing"] do
          node = GraphAssertions.find_node(context.graph, "component", child.id, name)

          assert node,
                 "expected child #{child.module_name} (#{child.type}) to have a #{name} node with require_unit_tests at default true"
        end

        {:ok, context}
      end

      and_ "the BDD coverage node is present on the story", context do
        # bdd_specs_passing was removed in favor of stop-hook
        # enforcement; the surviving BDD-coverage gate is
        # bdd_specs_exist at the story level. Project-level
        # all_bdd_specs_passing was also removed for the same reason.
        node = GraphAssertions.find_node(context.graph, "story", context.story.id, "bdd_specs_exist")
        assert node, "expected story to have bdd_specs_exist node regardless of unit-tests flag"

        {:ok, context}
      end
    end
  end
end
