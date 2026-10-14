defmodule CodeMySpecSpex.Story562.Criterion6074Spex do
  @moduledoc """
  Story 562 — Connected Requirement Graph Across Entities
  Criterion 6074 — A container surface's `bdd_specs_exist` fans out
  to every direct child whose type supports the first surviving
  child-scoped def, instead of landing on the surface itself.

  Since the dependency junction (2026-10-13), the kickoff lands on the
  container's `dependencies_met`, which gates each child; the fan-out
  to the children is that junction's.

  Symmetric counterpart of criterion 5654 (container surface's
  `ready_for_qa` fans IN from every child's terminal).

  Reproduction: MarketMySpec runs with all three require_*
  toggles disabled. After filtering, the parent context_graph's
  first surviving def is the child-scoped `implementation_file`.
  Without dispatching by `node_scope`, the kickoff edge incorrectly
  targets `{"component", parent.id, "implementation_file"}` (a
  collision with the parent's own surviving def 11) instead of
  fanning out to `{"component", child.id, "implementation_file"}`
  for every direct child.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias CodeMySpecSpex.GraphAssertions
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Container kickoff fans out to children when first surviving def is child-scoped",
    criterion: 222 do
    scenario "bdd_specs_exist edges land on each child's impl_file, not on the parent context" do
      given_ :context_with_module_typed_children

      and_ "a story is linked to the container context", context do
        story =
          StoryHelpers.create_and_link(context.scope, context.parent_context.module_name,
            title: "Skills story",
            description: "Story linked to a container context.",
            acceptance_criteria: ["Some behavior holds"]
          )

        {:ok, Map.put(context, :story, story)}
      end

      when_ "the engineer views the component requirements", context do
        {:ok, _live, html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/requirements/graph?preload=true"
          )

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "bdd_specs_exist reaches each child's implementation_file through the container's junction",
            context do
        bdd_exist_key =
          GraphAssertions.node_key("story", context.story.id, "bdd_specs_exist")

        junction_key =
          GraphAssertions.node_key("component", context.parent_context.id, "dependencies_met")

        assert GraphAssertions.edge?(context.graph, bdd_exist_key, junction_key),
               "expected bdd_specs_exist → #{context.parent_context.module_name}.dependencies_met edge, missing"

        children = [context.child_strategy, context.child_overview]

        Enum.each(children, fn child ->
          target_key =
            GraphAssertions.node_key("component", child.id, "implementation_file")

          assert GraphAssertions.edge?(context.graph, junction_key, target_key),
                 "expected dependencies_met → #{child.module_name}.implementation_file edge, missing"
        end)

        {:ok, context}
      end

      and_ "bdd_specs_exist does NOT have an outgoing edge to the parent context's implementation_file",
           context do
        bdd_exist_key =
          GraphAssertions.node_key("story", context.story.id, "bdd_specs_exist")

        parent_target_key =
          GraphAssertions.node_key(
            "component",
            context.parent_context.id,
            "implementation_file"
          )

        refute GraphAssertions.edge?(context.graph, bdd_exist_key, parent_target_key),
               "expected NO bdd_specs_exist → #{context.parent_context.module_name}.implementation_file edge, but found one"

        {:ok, context}
      end
    end
  end
end
