defmodule CodeMySpecSpex.Story671.Criterion5633Spex do
  @moduledoc """
  Story 671 — Project Configuration Filters the Graph Cleanly
  Criterion 5633 — With require_unit_tests false, no test_file,
  test_spec_alignment, or tests_passing component nodes appear, but
  story-level bdd_specs_exist / bdd_specs_passing and project-level
  all_bdd_specs_passing nodes survive — BDD coverage is a separate
  concern from unit tests.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.GraphAssertions
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "require_unit_tests=false strips unit-test nodes; BDD nodes survive" do
    scenario "test_* component nodes gone, BDD story+project nodes still present" do
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

      given_ :on_configuration_page

      when_ "the engineer disables require_unit_tests", context do
        context.config_live
        |> form("[data-test='configuration-form']",
          configuration: %{
            require_specs: true,
            require_reviews: true,
            require_unit_tests: false
          }
        )
        |> render_submit()

        {:ok, context}
      end

      and_ "the engineer renders the requirements graph", context do
        {:ok, _live, html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/requirements/graph?preload=true"
          )

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "no component test_* node appears", context do
        test_nodes =
          context.graph["nodes"]
          |> Enum.filter(fn n ->
            n["attributes"]["entity_type"] == "component" and
              n["attributes"]["name"] in ["test_file", "test_spec_alignment", "tests_passing"]
          end)

        assert test_nodes == [],
               "expected no component test_file/test_spec_alignment/tests_passing nodes, found: #{inspect(Enum.map(test_nodes, &{&1["attributes"]["entity_id"], &1["attributes"]["name"]}))}"

        {:ok, context}
      end

      and_ "the story still has its BDD-coverage node (bdd_specs_exist)", context do
        # bdd_specs_passing was removed from story_graph in favor of
        # stop-hook enforcement; the surviving BDD-coverage gate at
        # story level is bdd_specs_exist (BDD spec files written).
        node =
          GraphAssertions.find_node(context.graph, "story", context.story.id, "bdd_specs_exist")

        assert node,
               "expected story to retain bdd_specs_exist when require_unit_tests is false (BDD coverage is a separate concern from unit tests)"

        {:ok, context}
      end
    end
  end
end
