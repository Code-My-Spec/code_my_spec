defmodule CodeMySpecSpex.Story553.Criterion5081Spex do
  @moduledoc """
  Story 553 — Project Configuration: Local quality gate settings
  Criterion 5081 — When an engineer turns off specs for rapid prototyping,
  they are no longer required in the requirements graph.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Engineer turns off specs for rapid prototyping" do
    scenario "specs are no longer required in the requirements graph" do
      given_ :synced_context_component
      given_ :story_linked_to_component
      given_ :on_configuration_page

      when_ "the engineer toggles require_specs off", context do
        context.config_live
        |> form("[data-test='configuration-form']", configuration: %{require_specs: false})
        |> render_submit()

        {:ok, context}
      end

      then_ "the requirements graph has implementation but no spec requirements",
            context do
        {:ok, _graph_live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/requirements/graph?preload=true")

        # Anchor: implementation_file is not affected by this toggle, so its
        # presence proves the graph has real content (guards against vacuous refutes).
        assert html =~ "implementation_file",
               "graph must contain implementation_file — toggle should not affect it"

        refute html =~ "spec_file",
               "graph must not contain spec_file after toggling require_specs off"

        refute html =~ "spec_valid",
               "graph must not contain spec_valid after toggling require_specs off"

        {:ok, context}
      end
    end
  end
end
