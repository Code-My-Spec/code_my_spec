defmodule CodeMySpecSpex.Story562.Criterion5651Spex do
  @moduledoc """
  Story 562 — Connected Requirement Graph Across Entities
  Criterion 5651 — When the surface has no cross-context
  dependencies, the story's `bdd_specs_exist` outgoing edge lands
  directly on the surface's first requirement. The kickoff
  expansion mustn't over-fire on graphs without deps.
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

  spex "A story whose surface has no deps kicks off directly at the surface" do
    scenario "bdd_specs_exist's only outgoing edge is the surface's first req" do
      given_ "a story linked to a standalone live_context with no deps", context do
        Enum.each(
          [
            {"Standalone", :live_context, []},
            {"Standalone.HomeLive", :liveview, ["Standalone"]}
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
          live(context.conn, "/projects/#{context.project.name}/files")

        sync_live |> element("button[phx-click='sync']") |> render_click()

        # The Standalone live_context itself depends on nothing, so the
        # surface's only "transitive dep" is the parent context — and we
        # need the chain to bottom out somewhere. Test against the
        # outermost component (the live_context parent).
        surface_ctx = Fixtures.get_component_by_module_name(context.scope, "Standalone")
        surface = Fixtures.get_component_by_module_name(context.scope, "Standalone.HomeLive")

        story =
          StoryHelpers.create_and_link(context.scope, "Standalone.HomeLive",
            title: "Standalone story",
            description: "Story for a surface with no cross-context deps.",
            acceptance_criteria: ["Surface renders"]
          )

        {:ok, Map.merge(context, %{surface_ctx: surface_ctx, surface: surface, story: story})}
      end

      when_ "the engineer opens the requirements graph", context do
        {:ok, _live, html} =
          live(context.conn, "/projects/#{context.project.name}/requirements/graph?preload=true")

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "bdd_specs_exist has an outgoing edge to the parent live_context's first req",
            context do
        # The liveview surface depends on its parent live_context, which has
        # no further deps — so the chain root IS the parent live_context.
        bdd_exist_key =
          GraphAssertions.node_key("story", context.story.id, "bdd_specs_exist")

        ctx_first_key =
          GraphAssertions.node_key("component", context.surface_ctx.id, "spec_file")

        assert GraphAssertions.edge?(context.graph, bdd_exist_key, ctx_first_key),
               "expected bdd_specs_exist to kickoff at the parent live_context's first requirement"

        {:ok, context}
      end

      and_ "bdd_specs_exist has no foreign component kickoff edges",
           context do
        bdd_exist_key =
          GraphAssertions.node_key("story", context.story.id, "bdd_specs_exist")

        component_targets =
          context.graph
          |> GraphAssertions.edges_from(bdd_exist_key)
          |> Enum.map(& &1["target"])
          # Filter to component kickoffs only — bdd_specs_exist also has
          # an internal-story prereq edge to qa_complete (since the now-
          # removed bdd_specs_passing gate moved out of the graph).
          |> Enum.filter(&String.starts_with?(&1, "component_"))

        # The kickoff should resolve to a single component, not multiple
        # (no deps to fan out into).
        assert length(component_targets) == 1,
               "expected exactly one component-kickoff edge from bdd_specs_exist when the surface has no extra deps, got: #{inspect(component_targets)}"

        {:ok, context}
      end
    end
  end
end
