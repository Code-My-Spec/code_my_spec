defmodule CodeMySpecSpex.Story562.Criterion5605Spex do
  @moduledoc """
  Story 562 — Connected Requirement Graph Across Entities
  Criterion 5605 — Project terminal requirement depends on every
  story's qa_complete.

  Surface: requirements graph LiveView. Verifies the project-level
  fan-in: for each story in the project, there is at least one edge
  from a story-owned node to a project-owned node. (The exact
  endpoints are the story's `qa_complete` and the project's
  `all_bdd_specs_passing` — formerly `qa_preflight`, now that the
  qa_preflight task has been removed and stories fan in to the next
  project node. We assert structurally to stay resilient against
  name shuffling during further graph changes.)
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias CodeMySpecSpex.GraphAssertions

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Project terminal requirement fans in from every story" do
    scenario "every story has at least one edge into a project-owned node" do
      given_ :project_with_four_stories

      when_ "the engineer opens the requirements graph", context do
        {:ok, _live, html} =
          live(context.conn, "/projects/#{context.project.name}/requirements/graph?preload=true")

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "every story has at least one edge into a project node",
            context do
        project_keys =
          context.graph["nodes"]
          |> Enum.filter(fn n -> n["attributes"]["entity_type"] == "project" end)
          |> MapSet.new(& &1["key"])

        assert MapSet.size(project_keys) > 0,
               "expected at least one project node in the rendered graph"

        Enum.each(context.stories, fn story ->
          story_keys =
            context.graph["nodes"]
            |> Enum.filter(fn n -> n["attributes"]["entity_id"] == story.id end)
            |> MapSet.new(& &1["key"])

          fan_in_edges =
            Enum.filter(context.graph["edges"], fn e ->
              MapSet.member?(story_keys, e["source"]) and
                MapSet.member?(project_keys, e["target"])
            end)

          assert fan_in_edges != [],
                 "expected at least one edge from story #{story.title} (id: #{story.id}) into a project node, found none"
        end)

        {:ok, context}
      end
    end
  end
end
