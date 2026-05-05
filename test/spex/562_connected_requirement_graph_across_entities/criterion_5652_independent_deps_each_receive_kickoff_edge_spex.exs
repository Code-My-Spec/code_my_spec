defmodule CodeMySpecSpex.Story562.Criterion5652Spex do
  @moduledoc """
  Story 562 — Connected Requirement Graph Across Entities
  Criterion 5652 — When the surface depends on two unrelated
  contexts (neither depends on the other), each receives a kickoff
  edge from the story's `bdd_specs_exist`. The direct edge to the
  surface is dropped because both dep paths subsume it.
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

  spex "Independent deps each receive their own kickoff edge" do
    scenario "bdd_specs_exist fans out to both deps; surface kickoff is subsumed" do
      given_ "a surface that depends on two unrelated contexts A and B", context do
        Enum.each(
          [
            {"DepA", :context, []},
            {"DepA.Item", :schema, []},
            {"DepB", :context, []},
            {"DepB.Item", :schema, []},
            {"FanCtx", :live_context, ["DepA", "DepB"]},
            {"FanCtx.FanLive", :liveview, ["FanCtx"]}
          ],
          fn {module_name, type, deps} ->
            content =
              case type do
                :context -> Content.context_spec(module_name, type: "context", dependencies: deps)
                :live_context -> Content.context_spec(module_name, type: "live_context", dependencies: deps)
                :liveview -> Content.liveview_spec(module_name, dependencies: deps)
                :schema -> Content.child_spec(module_name, type: "schema", dependencies: deps)
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

        dep_a = Fixtures.get_component_by_module_name(context.scope, "DepA")
        dep_b = Fixtures.get_component_by_module_name(context.scope, "DepB")
        surface_ctx = Fixtures.get_component_by_module_name(context.scope, "FanCtx")
        surface = Fixtures.get_component_by_module_name(context.scope, "FanCtx.FanLive")

        story =
          StoryHelpers.create_and_link(context.scope, "FanCtx.FanLive",
            title: "Fan story",
            description: "Story whose surface fans out to two unrelated contexts.",
            acceptance_criteria: ["Both deps render"]
          )

        {:ok,
         Map.merge(context, %{
           dep_a: dep_a,
           dep_b: dep_b,
           surface_ctx: surface_ctx,
           surface: surface,
           story: story
         })}
      end

      when_ "the engineer opens the requirements graph", context do
        {:ok, _live, html} =
          live(context.conn, "/projects/#{context.project.name}/requirements/graph?preload=true")

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "bdd_specs_exist has an outgoing edge to each independent dep",
            context do
        bdd_exist_key =
          GraphAssertions.node_key("story", context.story.id, "bdd_specs_exist")

        dep_a_key =
          GraphAssertions.node_key("component", context.dep_a.id, "spec_file")

        dep_b_key =
          GraphAssertions.node_key("component", context.dep_b.id, "spec_file")

        assert GraphAssertions.edge?(context.graph, bdd_exist_key, dep_a_key),
               "expected bdd_specs_exist → DepA.spec_file to be present"

        assert GraphAssertions.edge?(context.graph, bdd_exist_key, dep_b_key),
               "expected bdd_specs_exist → DepB.spec_file to be present"

        {:ok, context}
      end

      and_ "bdd_specs_exist has no direct outgoing edge to the surface or its parent live_context",
           context do
        bdd_exist_key =
          GraphAssertions.node_key("story", context.story.id, "bdd_specs_exist")

        for {label, comp} <- [
              {"surface live_context", context.surface_ctx},
              {"surface liveview", context.surface}
            ] do
          comp_first_key =
            GraphAssertions.node_key("component", comp.id, "spec_file")

          refute GraphAssertions.edge?(context.graph, bdd_exist_key, comp_first_key),
                 "expected no direct kickoff edge from bdd_specs_exist to #{label} (subsumed by paths through DepA / DepB)"
        end

        {:ok, context}
      end
    end
  end
end
