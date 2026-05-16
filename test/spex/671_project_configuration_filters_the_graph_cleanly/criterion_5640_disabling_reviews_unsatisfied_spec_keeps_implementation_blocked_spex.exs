defmodule CodeMySpecSpex.Story671.Criterion5640Spex do
  @moduledoc """
  Story 671 — Project Configuration Filters the Graph Cleanly
  Criterion 5640 — Disabling reviews on an unsatisfied-spec project
  keeps implementation_file blocked, not magically actionable. The
  filter must not vacuously promote impl_file just because review_file
  is gone.

  Topology: a parent context with a single schema child. The schema's
  spec is OVERWRITTEN with content missing required sections (so
  spec_valid for the child fails). The parent's implementation file
  is removed (so impl_file is unsatisfied). Reviews are disabled.

  Today's behavior (no splice): impl_file's review prereq is dropped,
  leaving only the child's impl_file as a real upstream — which is
  satisfied — so impl_file is vacuously promoted to actionable. The
  bug.

  After fix: impl_file's prereq splices through the filtered review
  chain to reach the child's spec_valid (unsatisfied), keeping
  impl_file properly blocked.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.GraphAssertions
  alias CodeMySpecSpex.GraphContentFixtures, as: Content

  @actionable "#f5f5f7"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Reviews disabled + child spec_valid unsatisfied → impl_file NOT actionable" do
    scenario "impl_file rendered blocked even though review_file is filtered" do
      given_ :context_with_three_children_in_satisfied_project

      and_ "the child schema's spec is overwritten with content missing required sections, and the parent impl is removed",
           context do
        # Keep the title + type so sync still recognizes the child,
        # but omit the required Fields section so spec_valid fails.
        :ok =
          Environments.write_file(context.environment, Content.spec_path("Reservations.Booking"), """
          # Reservations.Booking

          ## Type

          schema

          A spec stub missing the required Fields section.
          """)

        :ok = Environments.delete_file(context.environment, Content.impl_path("Reservations"))

        {:ok, sync_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/files")

        sync_live |> element("button[phx-click='sync']") |> render_click()
        {:ok, context}
      end

      given_ :on_configuration_page

      when_ "the engineer disables require_reviews", context do
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
          live(context.conn, "/projects/#{context.project.name}/requirements/graph?preload=true")

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "the parent's implementation_file is NOT actionable",
            context do
        impl_node =
          GraphAssertions.find_node(
            context.graph,
            "component",
            context.parent_context.id,
            "implementation_file"
          )

        assert impl_node,
               "expected the parent context's implementation_file node to be rendered"

        refute impl_node["attributes"]["color"] == @actionable,
               "expected parent impl_file NOT to render as actionable when the child's spec_valid is unsatisfied — got actionable color anyway, suggesting the filter vacuously promoted it past the removed review chain"

        {:ok, context}
      end

      and_ "the child schema's spec_valid is rendered as actionable",
           context do
        child_spec_valid =
          GraphAssertions.find_node(
            context.graph,
            "component",
            context.child_schema.id,
            "spec_valid"
          )

        assert child_spec_valid,
               "expected child schema's spec_valid node to be present (require_specs is true)"

        assert child_spec_valid["attributes"]["color"] == @actionable,
               "expected child schema's spec_valid to be the actionable item (since its spec content is invalid and spec_file is satisfied), got color: #{child_spec_valid["attributes"]["color"]}"

        {:ok, context}
      end
    end
  end
end
