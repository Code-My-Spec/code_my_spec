defmodule CodeMySpecSpex.Story562.Criterion5610Spex do
  @moduledoc """
  Story 562 — Connected Requirement Graph Across Entities
  Criterion 5610 — Unsatisfied Users context blocks Stories
  implementation even when Stories spec_valid is green.

  Surface: requirements graph LiveView. When the `Users` context's
  implementation is missing, no `Stories` implementation_file or
  tests_passing node should render as satisfied — Stories cannot
  proceed past its dependency.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.GraphAssertions
  alias CodeMySpecSpex.GraphContentFixtures, as: Content

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Failing dep blocks the dependent context's implementation" do
    scenario "no Stories implementation node renders satisfied while Users is incomplete" do
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
          live(context.conn, "/projects/#{context.project.name}/sync")

        sync_live |> element("button[phx-click='sync']") |> render_click()

        {:ok, context}
      end

      when_ "the engineer opens the requirements graph", context do
        {:ok, _live, html} =
          live(context.conn, "/projects/#{context.project.name}/requirements/graph?preload=true")

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "no Stories implementation_file or tests_passing node is satisfied",
            context do
        stories_ids = MapSet.new([context.stories_context.id, context.stories_child.id])
        satisfied_color = "#60a5fa"

        satisfied_impl_nodes =
          context.graph["nodes"]
          |> Enum.filter(fn n ->
            MapSet.member?(stories_ids, n["attributes"]["entity_id"]) and
              n["attributes"]["color"] == satisfied_color and
              n["attributes"]["name"] in ["implementation_file", "tests_passing"]
          end)

        assert satisfied_impl_nodes == [],
               "expected no satisfied Stories implementation/tests_passing nodes while Users is incomplete, found: #{inspect(Enum.map(satisfied_impl_nodes, &{&1["attributes"]["entity_id"], &1["attributes"]["name"]}))}"

        {:ok, context}
      end
    end
  end
end
