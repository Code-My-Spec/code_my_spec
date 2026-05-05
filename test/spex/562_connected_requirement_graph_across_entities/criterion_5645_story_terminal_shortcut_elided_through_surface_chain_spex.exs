defmodule CodeMySpecSpex.Story562.Criterion5645Spex do
  @moduledoc """
  Story 562 — Connected Requirement Graph Across Entities
  Criterion 5645 — A story's `bdd_specs_passing` has no direct
  incoming edge from `bdd_specs_exist` when a longer path through
  the linked surface component exists. The shortcut is pruned by
  transitive reduction; the surface terminal is the only direct
  upstream that survives.

  Without this rule the story's terminal is reachable in two ways
  — directly from `bdd_specs_exist` and through the component
  chain — and the rendered graph shows a long arrow that bypasses
  the actual work the story tracks.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias CodeMySpecSpex.GraphAssertions

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Direct bdd_specs_exist → bdd_specs_passing edge is pruned through the surface chain" do
    scenario "story terminal points only at the surface terminal; the internal shortcut is gone" do
      given_ :story_with_liveview_surface

      when_ "the engineer opens the requirements graph", context do
        {:ok, _live, html} =
          live(context.conn, "/projects/#{context.project.name}/requirements/graph?preload=true")

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "bdd_specs_passing has no incoming edge from bdd_specs_exist",
            context do
        passing_key =
          GraphAssertions.node_key("story", context.story.id, "bdd_specs_passing")

        exist_key =
          GraphAssertions.node_key("story", context.story.id, "bdd_specs_exist")

        shortcut =
          context.graph
          |> GraphAssertions.edges_to(passing_key)
          |> Enum.filter(fn e -> e["source"] == exist_key end)

        assert shortcut == [],
               "expected the direct bdd_specs_exist → bdd_specs_passing shortcut to be pruned by transitive reduction, found: #{inspect(Enum.map(shortcut, &{&1["source"], &1["target"]}))}"

        {:ok, context}
      end

      and_ "bdd_specs_passing's incoming chain reaches the surface terminal",
           context do
        passing_key =
          GraphAssertions.node_key("story", context.story.id, "bdd_specs_passing")

        surface_terminal_endpoints =
          context.graph
          |> GraphAssertions.edges_to(passing_key)
          |> Enum.map(& &1["source"])
          |> Enum.filter(&String.starts_with?(&1, "component_"))

        assert surface_terminal_endpoints != [],
               "expected bdd_specs_passing to have at least one incoming edge from a component node (the surface terminal), found incoming sources: #{inspect(GraphAssertions.edges_to(context.graph, passing_key) |> Enum.map(& &1["source"]))}"

        {:ok, context}
      end
    end
  end
end
