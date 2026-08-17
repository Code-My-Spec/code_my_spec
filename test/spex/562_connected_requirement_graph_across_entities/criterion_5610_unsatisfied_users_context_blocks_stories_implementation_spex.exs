defmodule CodeMySpecSpex.Story562.Criterion5610Spex do
  @moduledoc """
  Story 562 — Connected Requirement Graph Across Entities
  Criterion 5610 — Cross-context dependencies render as locally
  truthful: the unsatisfied upstream context's own terminal is shown
  as not satisfied; the cross-context dep edge constrains
  actionability but does not mutate downstream satisfaction.

  Under the local-truth redesign (rule ac254f5d), the dep edge from
  Users.terminal → Stories.first_req means Stories' first req is not
  actionable while Users' terminal is unsat — but Stories' own nodes
  report their own local check state.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.GraphAssertions
  alias CodeMySpecSpex.GraphContentFixtures, as: Content

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Cross-context dep renders local truth" do
    scenario "Users implementation_file renders as not satisfied when its file is missing" do
      given_ :cross_context_dependency

      and_ "the Users context's implementation file is removed", context do
        :ok =
          Environments.delete_file(
            context.environment,
            Content.impl_path(context.users_child.module_name)
          )

        :ok =
          Environments.delete_file(
            context.environment,
            Content.impl_path(context.users_context.module_name)
          )

        {:ok, sync_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        sync_live |> element("button[phx-click='sync']") |> render_click()

        {:ok, context}
      end

      when_ "the engineer opens the requirements graph", context do
        {:ok, _live, html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/requirements/graph?preload=true"
          )

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "Users' implementation_file nodes render as not satisfied",
            context do
        satisfied_color = "#ff3838"
        users_ids = MapSet.new([context.users_context.id, context.users_child.id])

        users_impl_nodes =
          Enum.filter(context.graph["nodes"], fn n ->
            MapSet.member?(users_ids, n["attributes"]["entity_id"]) and
              n["attributes"]["name"] == "implementation_file"
          end)

        assert users_impl_nodes != [],
               "expected the deleted Users implementation_file nodes to appear in the graph"

        satisfied =
          Enum.filter(users_impl_nodes, fn n ->
            n["attributes"]["color"] == satisfied_color
          end)

        assert satisfied == [],
               "expected Users' implementation_file nodes to render as not satisfied, found satisfied: #{inspect(Enum.map(satisfied, & &1["attributes"]["entity_id"]))}"

        {:ok, context}
      end
    end
  end
end
