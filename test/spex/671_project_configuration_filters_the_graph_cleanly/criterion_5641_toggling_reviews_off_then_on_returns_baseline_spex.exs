defmodule CodeMySpecSpex.Story671.Criterion5641Spex do
  @moduledoc """
  Story 671 — Project Configuration Filters the Graph Cleanly
  Criterion 5641 — Toggling require_reviews off then back on returns
  the original graph shape. Filtering is a pure function of current
  configuration: no leftover or orphan data remains from the
  intermediate disabled state.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.GraphAssertions

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Toggling reviews off then on returns the baseline graph" do
    scenario "post-toggle graph nodes and edges match the pre-toggle baseline" do
      given_ :context_with_three_children

      and_ "the engineer captures the baseline graph (defaults)", context do
        {:ok, _live, html} =
          live(context.conn, "/projects/#{context.project.name}/requirements/graph?preload=true")

        baseline = GraphAssertions.extract_graph!(html)
        {:ok, Map.put(context, :baseline, baseline)}
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

      and_ "the engineer re-enables require_reviews", context do
        context.config_live
        |> form("[data-test='configuration-form']",
          configuration: %{
            require_specs: true,
            require_reviews: true,
            require_unit_tests: true
          }
        )
        |> render_submit()

        {:ok, context}
      end

      and_ "the engineer re-renders the graph", context do
        {:ok, _live, html} =
          live(context.conn, "/projects/#{context.project.name}/requirements/graph?preload=true")

        {:ok, Map.put(context, :after_toggle, GraphAssertions.extract_graph!(html))}
      end

      then_ "the post-toggle node set is identical to the baseline", context do
        baseline_keys =
          context.baseline["nodes"] |> Enum.map(& &1["key"]) |> Enum.sort()

        after_keys =
          context.after_toggle["nodes"] |> Enum.map(& &1["key"]) |> Enum.sort()

        assert baseline_keys == after_keys,
               "expected the post-toggle node set to match the baseline, missing: #{inspect(baseline_keys -- after_keys)}, extra: #{inspect(after_keys -- baseline_keys)}"

        {:ok, context}
      end

      and_ "the post-toggle edge set is identical to the baseline",
           context do
        baseline_edges =
          context.baseline["edges"]
          |> Enum.map(fn e -> {e["source"], e["target"]} end)
          |> Enum.sort()

        after_edges =
          context.after_toggle["edges"]
          |> Enum.map(fn e -> {e["source"], e["target"]} end)
          |> Enum.sort()

        assert baseline_edges == after_edges,
               "expected the post-toggle edge set to match the baseline, missing: #{inspect(baseline_edges -- after_edges)}, extra: #{inspect(after_edges -- baseline_edges)}"

        {:ok, context}
      end
    end
  end
end
