defmodule CodeMySpecSpex.Story553.Criterion5084Spex do
  @moduledoc """
  Story 553 — Project Configuration: Local quality gate settings
  Criterion 5084 — When an engineer turns off specs, reviews, and unit tests,
  only implementation file requirements remain in the requirements graph.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Engineer turns everything off for rapid prototyping" do
    scenario "only implementation requirements remain in the graph" do
      given_ :synced_context_component
      given_ :story_linked_to_component
      given_ :on_configuration_page

      when_ "the engineer toggles all three requirement flags off", context do
        context.config_live
        |> form("[data-test='configuration-form']",
          configuration: %{
            require_specs: false,
            require_reviews: false,
            require_unit_tests: false
          }
        )
        |> render_submit()

        {:ok, context}
      end

      then_ "only implementation_file remains in the graph", context do
        {:ok, _graph_live, html} =
          live(context.conn, ~p"/projects/#{context.project.name}/requirements/graph")

        # Anchor: implementation_file is never filtered — proves the graph
        # was actually produced and not empty for unrelated reasons.
        assert html =~ "implementation_file",
               "graph must still contain implementation_file"

        refute html =~ "spec_file"
        refute html =~ "spec_valid"
        refute html =~ "review_file"
        refute html =~ "review_valid"
        refute html =~ "test_file"
        refute html =~ "tests_passing"

        {:ok, context}
      end
    end
  end
end
