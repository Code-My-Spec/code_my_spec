defmodule CodeMySpecSpex.Story562.Criterion5655Spex do
  @moduledoc """
  Story 562 — Connected Requirement Graph Across Entities
  Criterion 5655 — A container surface with exactly one child
  collapses to that child's terminal only. No parent-scope edges
  feed bdd_specs_passing — the parent has no terminal of its own,
  and any direct edge would be subsumed by the longer path through
  the child anyway.
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

  spex "Container with one child collapses to that child's terminal" do
    scenario "bdd_specs_passing has exactly one incoming edge from the lone child's tests_passing" do
      given_ "a live_context with exactly one liveview child", context do
        Enum.each(
          [
            {"SoloLive", :live_context, []},
            {"SoloLive.OnlyLive", :liveview, []}
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

        surface = Fixtures.get_component_by_module_name(context.scope, "SoloLive")
        only = Fixtures.get_component_by_module_name(context.scope, "SoloLive.OnlyLive")

        story =
          StoryHelpers.create_and_link(context.scope, "SoloLive",
            title: "Solo container story",
            description: "Story whose surface is a container with one child.",
            acceptance_criteria: ["Only child renders"]
          )

        {:ok, Map.merge(context, %{surface: surface, only: only, story: story})}
      end

      when_ "the engineer opens the requirements graph", context do
        {:ok, _live, html} =
          live(context.conn, "/projects/#{context.project.name}/requirements/graph")

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "bdd_specs_passing has exactly one incoming edge from the only child's tests_passing",
            context do
        passing_key =
          GraphAssertions.node_key("story", context.story.id, "bdd_specs_passing")

        only_terminal =
          GraphAssertions.node_key("component", context.only.id, "tests_passing")

        sources =
          context.graph
          |> GraphAssertions.edges_to(passing_key)
          |> Enum.map(& &1["source"])

        assert sources == [only_terminal],
               "expected bdd_specs_passing's only incoming edge to be #{only_terminal}, got: #{inspect(sources)}"

        {:ok, context}
      end
    end
  end
end
