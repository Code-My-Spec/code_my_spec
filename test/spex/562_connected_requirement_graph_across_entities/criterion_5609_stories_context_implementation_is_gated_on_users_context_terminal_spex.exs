defmodule CodeMySpecSpex.Story562.Criterion5609Spex do
  @moduledoc """
  Story 562 — Connected Requirement Graph Across Entities
  Criterion 5609 — Stories context children's implementation work is
  gated on the Users context terminal requirement.

  Surface: requirements graph LiveView. When the `Stories` context
  declares a dependency on the `Users` context, there must be at
  least one edge from a `Users`-owned node into a `Stories`-owned
  node — establishing the cross-context ordering relationship.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias CodeMySpecSpex.GraphAssertions

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Cross-context dependency creates a graph edge from dep to dependent" do
    scenario "an edge runs from a Users node into a Stories node" do
      given_ :cross_context_dependency

      when_ "the engineer opens the requirements graph", context do
        {:ok, _live, html} =
          live(context.conn, "/app/projects/#{context.project.name}/requirements/graph?preload=true")

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "at least one edge runs from a Users-owned node into a Stories-owned node",
            context do
        users_ids = MapSet.new([context.users_context.id, context.users_child.id])
        stories_ids = MapSet.new([context.stories_context.id, context.stories_child.id])

        users_keys =
          context.graph["nodes"]
          |> Enum.filter(fn n -> MapSet.member?(users_ids, n["attributes"]["entity_id"]) end)
          |> MapSet.new(& &1["key"])

        stories_keys =
          context.graph["nodes"]
          |> Enum.filter(fn n -> MapSet.member?(stories_ids, n["attributes"]["entity_id"]) end)
          |> MapSet.new(& &1["key"])

        cross_context_edges =
          Enum.filter(context.graph["edges"], fn e ->
            MapSet.member?(users_keys, e["source"]) and
              MapSet.member?(stories_keys, e["target"])
          end)

        assert cross_context_edges != [],
               "expected at least one cross-context edge from Users into Stories, found none"

        {:ok, context}
      end
    end
  end
end
