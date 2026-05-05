defmodule CodeMySpecSpex.Story562.Criterion5654Spex do
  @moduledoc """
  Story 562 — Connected Requirement Graph Across Entities
  Criterion 5654 — A container surface (live_context with multiple
  children) feeds bdd_specs_passing from each child's terminal.
  The parent's own scope contributes nothing — the parent has no
  terminal node of its own.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.GraphAssertions
  alias CodeMySpecSpex.GraphContentFixtures, as: Content
  alias CodeMySpecSpex.StoryHelpers

  @endpoint CodeMySpecLocalWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Container surface's bdd_specs_passing is gated on every child terminal" do
    scenario "two unrelated liveview children both feed bdd_specs_passing" do
      given_ "a live_context with two unrelated liveview children", context do
        Enum.each(
          [
            {"DualLive", :live_context, []},
            {"DualLive.LeftLive", :liveview, []},
            {"DualLive.RightLive", :liveview, []}
          ],
          fn {module_name, type, deps} ->
            content =
              case type do
                :live_context -> Content.context_spec(module_name, type: "live_context", dependencies: deps)
                :liveview -> Content.liveview_spec(module_name, dependencies: deps)
              end

            :ok = Environments.write_file(context.environment, Content.spec_path(module_name), content)

            :ok =
              Environments.write_file(
                context.environment,
                Content.impl_path(module_name),
                Content.impl_file(module_name)
              )
          end
        )

        {:ok, sync_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/sync")

        sync_live |> element("button[phx-click='sync']") |> render_click()

        surface = Fixtures.get_component_by_module_name(context.scope, "DualLive")
        left = Fixtures.get_component_by_module_name(context.scope, "DualLive.LeftLive")
        right = Fixtures.get_component_by_module_name(context.scope, "DualLive.RightLive")

        story =
          StoryHelpers.create_and_link(context.scope, "DualLive",
            title: "Dual surface story",
            description: "Story whose surface is a container with two unrelated children.",
            acceptance_criteria: ["Both children render"]
          )

        {:ok, Map.merge(context, %{surface: surface, left: left, right: right, story: story})}
      end

      when_ "the engineer opens the requirements graph", context do
        {:ok, _live, html} =
          live(context.conn, "/projects/#{context.project.name}/requirements/graph?preload=true")

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "bdd_specs_passing has incoming edges from both children's tests_passing",
            context do
        passing_key =
          GraphAssertions.node_key("story", context.story.id, "bdd_specs_passing")

        sources =
          context.graph
          |> GraphAssertions.edges_to(passing_key)
          |> Enum.map(& &1["source"])
          |> MapSet.new()

        left_terminal =
          GraphAssertions.node_key("component", context.left.id, "tests_passing")

        right_terminal =
          GraphAssertions.node_key("component", context.right.id, "tests_passing")

        assert MapSet.member?(sources, left_terminal),
               "expected bdd_specs_passing's incoming edges to include #{left_terminal}, got: #{inspect(MapSet.to_list(sources))}"

        assert MapSet.member?(sources, right_terminal),
               "expected bdd_specs_passing's incoming edges to include #{right_terminal}, got: #{inspect(MapSet.to_list(sources))}"

        {:ok, context}
      end

      and_ "bdd_specs_passing has no incoming edge from a parent-scope live_context node",
           context do
        passing_key =
          GraphAssertions.node_key("story", context.story.id, "bdd_specs_passing")

        # The DualLive surface is a live_context. Its parent-scope nodes
        # are spec_file / spec_valid / review_file / review_valid. None
        # of those should feed bdd_specs_passing.
        bad =
          context.graph
          |> GraphAssertions.edges_to(passing_key)
          |> Enum.filter(fn e ->
            String.starts_with?(e["source"], "component_") and
              String.contains?(e["source"], to_string(context.surface.id) |> String.replace("-", ""))
          end)

        assert bad == [],
               "expected no incoming edges from the live_context parent's own nodes, found: #{inspect(Enum.map(bad, & &1["source"]))}"

        {:ok, context}
      end
    end
  end
end
