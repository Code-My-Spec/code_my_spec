defmodule CodeMySpecSpex.Story671.Criterion5642Spex do
  @moduledoc """
  Story 671 — Project Configuration Filters the Graph Cleanly
  Criterion 5642 — Multiple toggle cycles produce a graph state
  determined SOLELY by the current config — no leftover nodes from
  previous configs.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.GraphAssertions

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Multi-toggle cycles end at a graph determined only by current config" do
    scenario "after several flips, final default-config graph matches a fresh default-config graph" do
      given_ :context_with_three_children

      and_ "the engineer captures the baseline (all true) graph", context do
        {:ok, _live, html} =
          live(context.conn, "/projects/#{context.project.name}/requirements/graph?preload=true")

        {:ok, Map.put(context, :baseline, GraphAssertions.extract_graph!(html))}
      end

      given_ :on_configuration_page

      when_ "the engineer flips through several configurations and back", context do
        flip_through(context, [
          # specs off, reviews on, tests off
          %{require_specs: false, require_reviews: true, require_unit_tests: false},
          # specs on, reviews off, tests on
          %{require_specs: true, require_reviews: false, require_unit_tests: true},
          # back to all true
          %{require_specs: true, require_reviews: true, require_unit_tests: true}
        ])

        {:ok, context}
      end

      and_ "the engineer renders the graph at the final state", context do
        {:ok, _live, html} =
          live(context.conn, "/projects/#{context.project.name}/requirements/graph?preload=true")

        {:ok, Map.put(context, :final, GraphAssertions.extract_graph!(html))}
      end

      then_ "the final graph matches the baseline node-for-node and edge-for-edge",
            context do
        baseline_keys = context.baseline["nodes"] |> Enum.map(& &1["key"]) |> Enum.sort()
        final_keys = context.final["nodes"] |> Enum.map(& &1["key"]) |> Enum.sort()

        assert baseline_keys == final_keys,
               "expected final graph nodes to equal the baseline; missing: #{inspect(baseline_keys -- final_keys)}, extra: #{inspect(final_keys -- baseline_keys)}"

        baseline_edges =
          context.baseline["edges"] |> Enum.map(&{&1["source"], &1["target"]}) |> Enum.sort()

        final_edges =
          context.final["edges"] |> Enum.map(&{&1["source"], &1["target"]}) |> Enum.sort()

        assert baseline_edges == final_edges,
               "expected final graph edges to equal the baseline; missing: #{inspect(baseline_edges -- final_edges)}, extra: #{inspect(final_edges -- baseline_edges)}"

        {:ok, context}
      end
    end
  end

  defp flip_through(context, configs) do
    Enum.each(configs, fn cfg ->
      context.config_live
      |> form("[data-test='configuration-form']", configuration: cfg)
      |> render_submit()
    end)
  end
end
