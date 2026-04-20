defmodule CodeMySpecSpex.Story553.Criterion5082Spex do
  @moduledoc """
  Story 553 — Project Configuration: Local quality gate settings
  Criterion 5082 — When an engineer turns off design reviews but keeps specs
  required, specs still appear in the requirements graph but reviews do not.
  """

  use CodeMySpecSpex.Case

  import_givens CodeMySpecSpex.SharedGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Engineer requires specs but not design reviews" do
    scenario "specs remain in the requirements graph but reviews do not" do
      given_ :synced_context_component
      given_ :story_linked_to_component
      given_ :on_configuration_page

      when_ "the engineer toggles require_reviews off but keeps require_specs on",
            context do
        context.config_live
        |> form("[data-test='configuration-form']",
          configuration: %{require_specs: true, require_reviews: false}
        )
        |> render_submit()

        {:ok, context}
      end

      then_ "the requirements graph still has specs but no longer has reviews",
            context do
        {:ok, _graph_live, html} =
          live(context.conn, ~p"/projects/#{context.project.name}/requirements/graph")

        # Anchor: spec_file is the thing we kept enabled — its presence proves
        # the graph has real content and specs are still flowing through.
        assert html =~ "spec_file",
               "graph must still contain spec_file after toggling require_reviews off"

        assert html =~ "spec_valid",
               "graph must still contain spec_valid after toggling require_reviews off"

        refute html =~ "review_file",
               "graph must not contain review_file after toggling require_reviews off"

        refute html =~ "review_valid",
               "graph must not contain review_valid after toggling require_reviews off"

        :ok
      end
    end
  end
end
