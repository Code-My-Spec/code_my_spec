defmodule CodeMySpecSpex.Story562.Criterion5650Spex do
  @moduledoc """
  Story 562 — Connected Requirement Graph Across Entities
  Criterion 5650 — In a multi-level dep chain (surface S → dep A →
  dep B), the story's `bdd_specs_exist` collapses to the deepest
  dep's first requirement (B). All intermediate hops are subsumed
  by the longer path and dropped by transitive reduction.
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

  spex "Story kickoff resolves to the deepest dep in a chain" do
    scenario "bdd_specs_exist's only outgoing edge is to the chain's root context" do
      given_ "a 3-level chain: surface S depends on A, A depends on B", context do
        write_chain(context.environment, [
          {"BaseContext", :context, []},
          {"BaseContext.Item", :schema, []},
          {"MiddleContext", :context, ["BaseContext"]},
          {"MiddleContext.Item", :schema, []},
          {"SurfaceContext", :live_context, ["MiddleContext"]},
          {"SurfaceContext.HomeLive", :liveview, ["SurfaceContext"]}
        ])

        sync_project(context)

        base = Fixtures.get_component_by_module_name(context.scope, "BaseContext")
        middle = Fixtures.get_component_by_module_name(context.scope, "MiddleContext")
        surface_ctx = Fixtures.get_component_by_module_name(context.scope, "SurfaceContext")
        surface = Fixtures.get_component_by_module_name(context.scope, "SurfaceContext.HomeLive")

        story =
          StoryHelpers.create_and_link(context.scope, "SurfaceContext.HomeLive",
            title: "Chain story",
            description: "Story whose surface depends on a chain of contexts.",
            acceptance_criteria: ["Chain renders correctly"]
          )

        {:ok,
         Map.merge(context, %{
           base: base,
           middle: middle,
           surface_ctx: surface_ctx,
           surface: surface,
           story: story
         })}
      end

      when_ "the engineer opens the requirements graph", context do
        {:ok, _live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/requirements/graph?preload=true")

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "bdd_specs_exist's only component-bound outgoing edge is to BaseContext's first requirement",
            context do
        bdd_exist_key =
          GraphAssertions.node_key("story", context.story.id, "bdd_specs_exist")

        outgoing = GraphAssertions.edges_from(context.graph, bdd_exist_key)
        # bdd_specs_exist also has an internal-story prereq edge to
        # qa_complete (replacing the now-removed bdd_specs_passing
        # gate); we only care about the surface-tree kickoff edges
        # here, so filter to component targets.
        component_targets =
          outgoing
          |> Enum.map(& &1["target"])
          |> Enum.filter(&String.starts_with?(&1, "component_"))

        base_first_key =
          GraphAssertions.node_key("component", context.base.id, "spec_file")

        assert component_targets == [base_first_key],
               "expected bdd_specs_exist's only component kickoff edge to be BaseContext.spec_file (the chain's root), got: #{inspect(component_targets)}"

        {:ok, context}
      end

      and_ "no kickoff edges land on the intermediate or surface components",
           context do
        bdd_exist_key =
          GraphAssertions.node_key("story", context.story.id, "bdd_specs_exist")

        for {label, comp} <- [
              {"middle (A)", context.middle},
              {"surface context (S)", context.surface_ctx},
              {"surface liveview", context.surface}
            ] do
          comp_first_key =
            GraphAssertions.node_key("component", comp.id, "spec_file")

          refute GraphAssertions.edge?(context.graph, bdd_exist_key, comp_first_key),
                 "expected no kickoff edge from bdd_specs_exist to #{label} (subsumed by deeper path)"
        end

        {:ok, context}
      end
    end
  end

  defp write_chain(env, specs) do
    Enum.each(specs, fn {module_name, type, deps} ->
      content = spec_content_for(type, module_name, deps)

      :ok = Environments.write_file(env, Content.spec_path(module_name), content)
      :ok = Environments.write_file(env, Content.impl_path(module_name), Content.impl_file(module_name))
    end)
  end

  defp sync_project(context) do
    {:ok, sync_live, _html} =
      live(context.conn, "/app/projects/#{context.project.id}/files")

    sync_live |> element("button[phx-click='sync']") |> render_click()
    :ok
  end
  defp spec_content_for(:context, module_name, deps),
    do: Content.context_spec(module_name, type: "context", dependencies: deps)

  defp spec_content_for(:live_context, module_name, deps),
    do: Content.context_spec(module_name, type: "live_context", dependencies: deps)

  defp spec_content_for(:liveview, module_name, deps),
    do: Content.liveview_spec(module_name, dependencies: deps)

  defp spec_content_for(:schema, module_name, deps),
    do: Content.child_spec(module_name, type: "schema", dependencies: deps)
end
