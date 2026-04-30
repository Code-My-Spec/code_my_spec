defmodule CodeMySpecSpex.Story562.Criterion5656Spex do
  @moduledoc """
  Story 562 — Connected Requirement Graph Across Entities
  Criterion 5656 — When two sibling children of a container surface
  are linked by a cross-context dependency (B depends on A), only
  the deeper child's terminal feeds bdd_specs_passing. A's terminal
  is subsumed by the longer path A.tests_passing →
  B.implementation_file → B.tests_passing → bdd_specs_passing.
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

  spex "Sibling children with a dep collapse to the deeper terminal" do
    scenario "B depends on A → only B.tests_passing feeds bdd_specs_passing" do
      given_ "a live_context with two liveview children where B depends on A", context do
        Enum.each(
          [
            {"ChainLive", :live_context, []},
            {"ChainLive.LiveA", :liveview, []},
            {"ChainLive.LiveB", :liveview, ["ChainLive.LiveA"]}
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

        surface = Fixtures.get_component_by_module_name(context.scope, "ChainLive")
        live_a = Fixtures.get_component_by_module_name(context.scope, "ChainLive.LiveA")
        live_b = Fixtures.get_component_by_module_name(context.scope, "ChainLive.LiveB")

        story =
          StoryHelpers.create_and_link(context.scope, "ChainLive",
            title: "Chain surface story",
            description: "Story whose surface contains two siblings, B depending on A.",
            acceptance_criteria: ["Chain renders"]
          )

        {:ok,
         Map.merge(context, %{surface: surface, live_a: live_a, live_b: live_b, story: story})}
      end

      when_ "the engineer opens the requirements graph", context do
        {:ok, _live, html} =
          live(context.conn, "/projects/#{context.project.name}/requirements/graph")

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "bdd_specs_passing has incoming from B.tests_passing",
            context do
        passing_key =
          GraphAssertions.node_key("story", context.story.id, "bdd_specs_passing")

        b_terminal =
          GraphAssertions.node_key("component", context.live_b.id, "tests_passing")

        assert GraphAssertions.edge?(context.graph, b_terminal, passing_key),
               "expected B.tests_passing → bdd_specs_passing to be present"

        {:ok, context}
      end

      and_ "bdd_specs_passing has no incoming from A.tests_passing (subsumed by B's chain)",
           context do
        passing_key =
          GraphAssertions.node_key("story", context.story.id, "bdd_specs_passing")

        a_terminal =
          GraphAssertions.node_key("component", context.live_a.id, "tests_passing")

        refute GraphAssertions.edge?(context.graph, a_terminal, passing_key),
               "expected A.tests_passing → bdd_specs_passing to be subsumed and dropped (longer path through B exists)"

        {:ok, context}
      end
    end
  end
end
