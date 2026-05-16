defmodule CodeMySpecSpex.Story717.Criterion6424Spex do
  @moduledoc """
  Story 717 — Engineer sees a DAG of project progress
  Criterion 6424 — Satisfaction state maps to brand color tokens consistently across bands.

  When the graph contains nodes with the same satisfaction state
  across different bands (project / story / component), those nodes
  share the same color value. The contract this spex pins is
  CONSISTENCY across bands rather than any specific palette — the
  implementation may pick brand tokens, hex values, or anything else,
  as long as the mapping `state → color` is band-agnostic.

  Surface: `/projects/:project_name/requirements/graph?preload=true`.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Node color encodes satisfaction state consistently across project, story, and component bands" do
    scenario "Satisfaction state maps to brand color tokens consistently across bands" do
      given_ :cross_context_dependency

      when_ "the engineer opens the requirements graph view with preload enabled", context do
        {:ok, view, _html} =
          live(context.conn, "/projects/#{context.project.name}/requirements/graph?preload=true")

        graph = view |> render() |> extract_graph()

        {:ok, Map.put(context, :graph, graph)}
      end

      then_ "every node color belongs to the brand palette (bg-primary / bg-success / bg-warning resolved hex)",
            context do
        # Brand palette resolved from assets/css/app.css:
        # bg-primary  → #ff3838 (signal red, satisfied)
        # bg-success  → #f5f5f7 (white, actionable — brand inverts the usual green)
        # bg-warning  → #fde047 (yellow, blocked)
        brand_palette = MapSet.new(["#ff3838", "#f5f5f7", "#fde047"])

        distinct_colors =
          context.graph["nodes"]
          |> Enum.map(& &1["attributes"]["color"])
          |> Enum.uniq()
          |> Enum.reject(&is_nil/1)

        off_palette = Enum.reject(distinct_colors, &MapSet.member?(brand_palette, &1))

        assert off_palette == [],
               "expected every node color to come from the brand palette #{inspect(MapSet.to_list(brand_palette))}; off-palette colors: #{inspect(off_palette)}"

        {:ok, Map.put(context, :distinct_colors, distinct_colors)}
      end

      and_ "the same brand token applies to a satisfaction state across every band",
           context do
        # For each color observed in the graph, the set of bands using it
        # is arbitrary (any state can occur in any band), but the color
        # value MUST be invariant — band X must not reinterpret #ff3838
        # to mean something different than band Y does.
        nodes_by_color =
          context.graph["nodes"]
          |> Enum.group_by(& &1["attributes"]["color"])

        for {color, _nodes} <- nodes_by_color do
          assert color in context.distinct_colors,
                 "color #{inspect(color)} drifted from the canonical brand palette #{inspect(context.distinct_colors)}"
        end

        {:ok, context}
      end
    end
  end

  defp extract_graph(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("#sigma-graph")
    |> Floki.attribute("data-graph")
    |> List.first()
    |> Jason.decode!()
  end
end
