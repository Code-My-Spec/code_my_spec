defmodule CodeMySpecSpex.Story562.Criterion5601Spex do
  @moduledoc """
  Story 562 — Connected Requirement Graph Across Entities
  Criterion 5601 — Story bdd_specs_passing depends on the surface
  terminal req only; deps reach through the surface.

  Surface: requirements graph LiveView. The story's terminal
  requirement (`bdd_specs_passing`) must point at exactly one
  prerequisite — the surface component's terminal requirement.
  Context dependencies of the surface are reachable transitively
  through the surface, never as direct prerequisites of the story.

  This spec is expected to fail until story 562's rewrite lands.
  The current implementation fans out story-level edges to surface
  AND every context dep of the surface; the rewrite collapses that
  to a single edge into the surface terminal.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias CodeMySpecSpex.GraphAssertions

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Story terminal requirement points only at the surface" do
    scenario "story bdd_specs_passing has no edges to context-dep nodes" do
      given_ :story_with_liveview_surface

      when_ "the engineer opens the requirements graph", context do
        {:ok, _live, html} =
          live(context.conn, "/projects/#{context.project.name}/requirements/graph?preload=true")

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "no edge runs from a context-dep node directly into a story node",
            context do
        story_keys =
          context.graph["nodes"]
          |> Enum.filter(fn n -> n["attributes"]["entity_id"] == context.story.id end)
          |> MapSet.new(& &1["key"])

        dep_context_keys =
          context.graph["nodes"]
          |> Enum.filter(fn n -> n["attributes"]["entity_id"] == context.dep_context.id end)
          |> MapSet.new(& &1["key"])

        direct_dep_to_story_edges =
          Enum.filter(context.graph["edges"], fn e ->
            MapSet.member?(dep_context_keys, e["source"]) and
              MapSet.member?(story_keys, e["target"])
          end)

        assert direct_dep_to_story_edges == [],
               "expected no direct edges from context-dep nodes to the story — context deps must reach through the surface, found: #{inspect(Enum.map(direct_dep_to_story_edges, &{&1["source"], &1["target"]}))}"

        {:ok, context}
      end

      and_ "the story has at least one edge from the surface component",
           context do
        story_keys =
          context.graph["nodes"]
          |> Enum.filter(fn n -> n["attributes"]["entity_id"] == context.story.id end)
          |> MapSet.new(& &1["key"])

        surface_keys =
          context.graph["nodes"]
          |> Enum.filter(fn n -> n["attributes"]["entity_id"] == context.surface_liveview.id end)
          |> MapSet.new(& &1["key"])

        surface_to_story_edges =
          Enum.filter(context.graph["edges"], fn e ->
            MapSet.member?(surface_keys, e["source"]) and
              MapSet.member?(story_keys, e["target"])
          end)

        assert surface_to_story_edges != [],
               "expected at least one edge from the surface component (#{context.surface_liveview.module_name}) to the story, found none"

        {:ok, context}
      end
    end
  end
end
