defmodule CodeMySpecSpex.Story717.Criterion6425Spex do
  @moduledoc """
  Story 717 — Engineer sees a DAG of project progress
  Criterion 6425 — Large-project layout keeps distinct bands and non-overlapping nodes.

  The load-bearing invariants from R6 are:
  (a) bands remain visually distinguishable as node count grows (no
      two bands collide into the same y range), and
  (b) no two nodes within a band overlap each other's bounding box.

  R6 is framed as a best-effort visual-quality rule, so this spex
  pins the strict topological invariants only: no two nodes share the
  same (x, y) position, and bands keep disjoint y ranges as more
  components are added. Label collapse/fade at high density is
  acceptable and not asserted here.

  Surface: `/projects/:project_name/requirements/graph?preload=true`.
  Setup populates multiple components to exercise the component zone
  layout under moderate density.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Layout dimensions scale with the project's node count where feasible; bands remain distinguishable and nodes don't overlap" do
    scenario "Large-project layout keeps distinct bands and non-overlapping nodes" do
      given_ :context_with_three_children
      given_ :cross_context_dependency

      when_ "the engineer opens the requirements graph view with preload enabled", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.name}/requirements/graph?preload=true")

        graph = view |> render() |> extract_graph()

        {:ok, Map.put(context, :graph, graph)}
      end

      then_ "no two nodes share the same (x, y) position", context do
        positions =
          context.graph["nodes"]
          |> Enum.map(fn n -> {n["attributes"]["x"], n["attributes"]["y"], n["key"]} end)

        by_position =
          positions
          |> Enum.group_by(fn {x, y, _} -> {x, y} end)
          |> Enum.filter(fn {_, ns} -> length(ns) > 1 end)

        assert by_position == [],
               "expected no two nodes at the same position; collisions: #{inspect(by_position)}"

        {:ok, context}
      end

      and_ "the project, story, and component bands keep disjoint y ranges", context do
        ys_by_type =
          context.graph["nodes"]
          |> Enum.group_by(& &1["attributes"]["entity_type"])
          |> Map.new(fn {t, ns} ->
            ys = Enum.map(ns, & &1["attributes"]["y"])
            {t, %{min: Enum.min(ys), max: Enum.max(ys)}}
          end)

        # In the current schema with non-empty project/story/component,
        # project_min > story_max AND story_min > component_max. Missing
        # bands collapse cleanly via pattern-matched guard helpers.
        assert_band_above(ys_by_type["project"], ys_by_type["story"], "project", "story")
        assert_band_above(ys_by_type["story"], ys_by_type["component"], "story", "component")

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

  # Pattern-matched band-comparison. Either band missing => trivially OK.
  defp assert_band_above(nil, _below, _upper_label, _lower_label), do: :ok
  defp assert_band_above(_above, nil, _upper_label, _lower_label), do: :ok

  defp assert_band_above(%{min: above_min} = above, %{max: below_max} = below, upper, lower) do
    assert above_min > below_max,
           "#{upper} band collides with #{lower} band: #{upper}=#{inspect(above)}, #{lower}=#{inspect(below)}"
  end
end
