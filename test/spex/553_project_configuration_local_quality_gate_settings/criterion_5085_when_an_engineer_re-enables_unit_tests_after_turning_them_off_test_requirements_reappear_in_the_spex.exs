defmodule CodeMySpecSpex.Story553.Criterion5085Spex do
  @moduledoc """
  Story 553 — Project Configuration: Local quality gate settings
  Criterion 5085 — When an engineer re-enables unit tests after turning them
  off, test requirements reappear in the requirements graph.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Engineer re-enables unit tests" do
    scenario "test requirements reappear in the graph" do
      given_ :synced_context_component
      given_ :story_linked_to_component
      given_ :on_configuration_page

      given_ "require_unit_tests has already been turned off", context do
        context.config_live
        |> form("[data-test='configuration-form']",
          configuration: %{require_unit_tests: false}
        )
        |> render_submit()

        {:ok, context}
      end

      when_ "the engineer toggles require_unit_tests back on", context do
        context.config_live
        |> form("[data-test='configuration-form']",
          configuration: %{require_unit_tests: true}
        )
        |> render_submit()

        {:ok, context}
      end

      then_ "the graph contains test_file and tests_passing again", context do
        {:ok, _graph_live, html} =
          live(context.conn, ~p"/projects/#{context.project.name}/requirements/graph?preload=true")

        assert html =~ "implementation_file"

        assert html =~ "test_file",
               "graph must contain test_file after re-enabling require_unit_tests"

        assert html =~ "tests_passing",
               "graph must contain tests_passing after re-enabling require_unit_tests"

        {:ok, context}
      end
    end
  end
end
