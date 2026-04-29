defmodule CodeMySpecSpex.Story562.Criterion5602Spex do
  @moduledoc """
  Story 562 — Connected Requirement Graph Across Entities
  Criterion 5602 — Failing context dep blocks the story transitively
  through the surface, not directly.

  Surface: requirements graph LiveView. With the dep context's
  implementation removed, the surface's terminal becomes
  unsatisfied, which transitively blocks the story's terminal.
  Critically, the block must come from the surface — there should
  be no direct story↔dep-context edge.

  Expected to fail until story 562 lands the chain semantics. Same
  rationale as 5601.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.GraphAssertions
  alias CodeMySpecSpex.GraphContentFixtures, as: Content

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Failing context dep blocks the story through the surface" do
    scenario "story is unsatisfied via the surface, with no direct edge to the dep context" do
      given_ :story_with_liveview_surface

      and_ "the dep context's implementation is removed", context do
        :ok =
          Environments.delete_file(
            context.environment,
            Content.impl_path(context.dep_context.module_name)
          )

        {:ok, sync_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/sync")

        sync_live |> element("button[phx-click='sync']") |> render_click()

        {:ok, context}
      end

      when_ "the engineer opens the requirements graph", context do
        {:ok, _live, html} =
          live(context.conn, "/projects/#{context.project.name}/requirements/graph")

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "the story's bdd_specs_passing is not satisfied",
            context do
        satisfied_color = "#60a5fa"

        satisfied_story_terminals =
          context.graph["nodes"]
          |> Enum.filter(fn n ->
            n["attributes"]["entity_id"] == context.story.id and
              n["attributes"]["color"] == satisfied_color and
              n["attributes"]["name"] == "bdd_specs_passing"
          end)

        assert satisfied_story_terminals == [],
               "expected the story's bdd_specs_passing to render unsatisfied while the dep context's implementation is missing, found it satisfied"

        {:ok, context}
      end

      and_ "no direct edge runs from the dep context into the story",
           context do
        story_keys =
          context.graph["nodes"]
          |> Enum.filter(fn n -> n["attributes"]["entity_id"] == context.story.id end)
          |> MapSet.new(& &1["key"])

        dep_keys =
          context.graph["nodes"]
          |> Enum.filter(fn n -> n["attributes"]["entity_id"] == context.dep_context.id end)
          |> MapSet.new(& &1["key"])

        direct_edges =
          Enum.filter(context.graph["edges"], fn e ->
            MapSet.member?(dep_keys, e["source"]) and
              MapSet.member?(story_keys, e["target"])
          end)

        assert direct_edges == [],
               "expected the block to be transitive (through the surface), but found direct dep→story edges: #{inspect(Enum.map(direct_edges, &{&1["source"], &1["target"]}))}"

        {:ok, context}
      end
    end
  end
end
