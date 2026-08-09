defmodule CodeMySpecSpex.Story553.Criterion5083Spex do
  @moduledoc """
  Story 553 — Project Configuration: Local quality gate settings
  Criterion 5083 — When an engineer turns off unit tests, the test file and
  tests_passing requirements no longer appear in the requirements graph.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Engineer turns off unit tests" do
    scenario "test file and tests_passing are removed from the requirements graph" do
      given_ :synced_context_component
      given_ :story_linked_to_component
      given_ :on_configuration_page

      when_ "the engineer toggles require_unit_tests off", context do
        context.config_live
        |> form("[data-test='configuration-form']",
          configuration: %{require_unit_tests: false}
        )
        |> render_submit()

        {:ok, context}
      end

      then_ "the graph still has spec + implementation but no test requirements",
            context do
        {:ok, _graph_live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/requirements/graph?preload=true")

        # Anchor: implementation_file is not affected — proves graph has content.
        assert html =~ "implementation_file",
               "graph must still contain implementation_file"

        assert html =~ "spec_file",
               "graph must still contain spec_file after toggling require_unit_tests off"

        refute html =~ "test_file",
               "graph must not contain test_file after toggling require_unit_tests off"

        refute html =~ "tests_passing",
               "graph must not contain tests_passing after toggling require_unit_tests off"

        {:ok, context}
      end
    end
  end
end
