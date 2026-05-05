defmodule CodeMySpecSpex.Story562.Criterion5599Spex do
  @moduledoc """
  Story 562 — Connected Requirement Graph Across Entities
  Criterion 5599 — A leaf turns green on its own check; a deep node
  stays red until its full chain is green.

  Surface: requirements graph LiveView. After syncing a context with
  three children, leaf-level requirements (`spec_file`) on each
  child should render satisfied — the spec files exist on disk.
  Deeper requirements (`tests_passing` on the parent) must NOT
  render satisfied because the children's chains are not complete
  (no test files written).
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias CodeMySpecSpex.GraphAssertions

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Satisfaction is computed top-down through prereq chains" do
    scenario "spec_file leaves are satisfied; deep parent terminals are not" do
      given_ :context_with_three_children

      when_ "the engineer opens the requirements graph", context do
        {:ok, _live, html} =
          live(context.conn, "/projects/#{context.project.name}/requirements/graph?preload=true")

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "every component's spec_file renders satisfied",
            context do
        satisfied_color = "#60a5fa"
        component_ids =
          MapSet.new([
            context.parent_context.id,
            context.child_schema.id,
            context.child_repository.id,
            context.child_service.id
          ])

        spec_file_nodes =
          context.graph["nodes"]
          |> Enum.filter(fn n ->
            MapSet.member?(component_ids, n["attributes"]["entity_id"]) and
              n["attributes"]["name"] == "spec_file"
          end)

        unsatisfied =
          Enum.reject(spec_file_nodes, fn n -> n["attributes"]["color"] == satisfied_color end)

        assert unsatisfied == [],
               "expected every component's spec_file to render satisfied (color #{satisfied_color}), found unsatisfied: #{inspect(Enum.map(unsatisfied, &{&1["attributes"]["entity_id"], &1["attributes"]["color"]}))}"

        {:ok, context}
      end

      and_ "the parent context's tests_passing is not satisfied",
           context do
        satisfied_color = "#60a5fa"

        satisfied_terminals =
          context.graph["nodes"]
          |> Enum.filter(fn n ->
            n["attributes"]["entity_id"] == context.parent_context.id and
              n["attributes"]["name"] == "tests_passing" and
              n["attributes"]["color"] == satisfied_color
          end)

        assert satisfied_terminals == [],
               "expected parent context's tests_passing to render unsatisfied (no test files written), found it satisfied"

        {:ok, context}
      end
    end
  end
end
