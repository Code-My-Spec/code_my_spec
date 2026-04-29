defmodule CodeMySpecSpex.Story562.Criterion5604Spex do
  @moduledoc """
  Story 562 — Connected Requirement Graph Across Entities
  Criterion 5604 — One missing child implementation blocks the parent
  context even when the others are complete.

  Surface: requirements graph at
  `/projects/:project/requirements/graph`. Tests that when one child
  has unsatisfied terminal state, the parent context's terminal
  cannot be marked satisfied — the graph propagates incomplete
  upstream state through to downstream nodes.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.GraphAssertions
  alias CodeMySpecSpex.GraphContentFixtures, as: Content

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Missing child implementation blocks the parent context" do
    scenario "parent context has no satisfied terminal when one child is incomplete" do
      given_ :context_with_three_children

      and_ "the schema child's implementation file is removed", context do
        :ok =
          Environments.delete_file(
            context.environment,
            Content.impl_path(context.child_schema.module_name)
          )

        # Re-sync so the missing file shows up as unsatisfied state
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

      then_ "no parent-owned node renders with satisfied state",
            context do
        parent_id = context.parent_context.id

        parent_nodes =
          Enum.filter(context.graph["nodes"], fn n ->
            n["attributes"]["entity_id"] == parent_id
          end)

        # Satisfied nodes use the satisfied color; actionable/blocked use others.
        # The parent's terminal must NOT be satisfied while a child is incomplete.
        satisfied_color = "#60a5fa"

        satisfied_parent_terminals =
          Enum.filter(parent_nodes, fn n ->
            n["attributes"]["color"] == satisfied_color and
              n["attributes"]["name"] in ["tests_passing", "implementation_file"]
          end)

        assert satisfied_parent_terminals == [],
               "expected no satisfied parent-context terminal node while a child implementation is missing, found: #{inspect(Enum.map(satisfied_parent_terminals, & &1["attributes"]["name"]))}"

        {:ok, context}
      end
    end
  end
end
