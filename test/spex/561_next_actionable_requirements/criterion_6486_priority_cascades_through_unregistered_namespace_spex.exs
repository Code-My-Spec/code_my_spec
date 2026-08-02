defmodule CodeMySpecSpex.Story561.Criterion6486Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements
  Criterion 6486 — Priority cascades to a deeply-nested component when
  an intermediate namespace is unregistered.

  Covers Rule f24fa177: "Priority cascades down `parent_component_id`
  chains to all descendants regardless of intermediate parent type."

  The existing 5904 spex covers ONE level of nesting (context → schema
  child). 6258 / 6259 cover non-container REGISTERED intermediates. This
  scenario closes the remaining gap: a deeply-nested component whose
  intermediate module namespace exists in module-name only — no spec
  file, no Component record, just a dotted-name gap.

  ## Mechanism

  `ComponentSync.find_nearest_ancestor/2` (lib/code_my_spec/files/
  component_sync.ex) walks the dotted module name upward and returns
  the closest REGISTERED component. So `MyApp.MyContext.Thing.Leaf`
  with no `MyApp.MyContext.Thing` Component record gets its
  `parent_component_id` set to `MyApp.MyContext`'s id, skipping the
  unregistered intermediate.

  `build_component_priority_map` in RequirementGraph then walks
  `parent_component_id` directly — it doesn't care that the chain
  jumped over a namespace gap, because the chain is already collapsed
  in the DB.

  ## What this asserts

  When `Thing.Leaf` has no implementation file, its component-level
  `implementation_file` requirement is unsatisfied. The agent should
  see `Thing.Leaf` in the actionable wave (priority-1 inherited
  through the chain), proving:
  1. ComponentSync correctly skipped the unregistered intermediate
  2. The graph's parent-chain priority walk reached the leaf
  3. The untethered-component filter did NOT drop it as an orphan
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.GraphContentFixtures, as: Content
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecSpex.StoryHelpers
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Priority cascades through an unregistered intermediate namespace" do
    scenario "deeply-nested leaf inherits priority via find_nearest_ancestor skipping the namespace gap" do
      given_ "the project chain is past kickoff so component-level work is the frontier",
             context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ "MyContext (registered, priority-1 story-linked) and Thing.Leaf (registered, deeply nested) with the intermediate `Thing` namespace UNregistered",
             context do
        env = context.environment

        # Top-level context, registered + has spec, impl, review files
        :ok =
          Environments.write_file(
            env,
            Content.spec_path("MyContext"),
            Content.context_spec("MyContext",
              type: "context",
              dependencies: [],
              children: []
            )
          )

        :ok =
          Environments.write_file(env, Content.impl_path("MyContext"), Content.impl_file("MyContext"))

        :ok =
          Environments.write_file(
            env,
            ".code_my_spec/spec/my_context/design_review.md",
            design_review_content("MyContext")
          )

        # Deeply-nested leaf — registered (spec file exists) but
        # intentionally NO impl file so its implementation_file req
        # stays unsatisfied. Module name has 3 dotted segments.
        :ok =
          Environments.write_file(
            env,
            Content.spec_path("MyContext.Thing.Leaf"),
            Content.child_spec("MyContext.Thing.Leaf", type: "schema")
          )

        # NOTE: NO file written for `MyContext.Thing` — that's the
        # whole point of this scenario. `Thing` is a pure
        # module-namespace gap with no Component record. After sync,
        # `Thing.Leaf.parent_component_id` must resolve to
        # `MyContext.id` directly.

        {:ok, sync_live, _html} = live(context.conn, "/app/projects/#{context.project.name}/files")
        sync_live |> element("button[phx-click='sync']") |> render_click()

        parent = Fixtures.get_component_by_module_name(context.scope, "MyContext")
        leaf = Fixtures.get_component_by_module_name(context.scope, "MyContext.Thing.Leaf")

        story =
          StoryHelpers.create_and_link(context.scope, "MyContext",
            title: "MyContext priority-1 cluster",
            description: "As a user, I want the MyContext cluster shipped first.",
            acceptance_criteria: ["MyContext renders"],
            priority: 1
          )

        :ok =
          ProjectStateFixtures.apply_story_chain_complete(context, story,
            persona_id: context.persona_id,
            rule_statement: "MyContext drives the priority-1 cluster",
            happy_title: "User sees the priority-1 cluster work first",
            happy_body:
              "Given the user opens MyContext\nWhen they request work\nThen MyContext.Thing.Leaf leads",
            failure_title: "Untethered descendant is excluded",
            failure_body:
              "Given the namespace gap is mishandled\nWhen the user requests work\nThen no MyContext.Thing.Leaf appears"
          )

        {:ok,
         Map.merge(context, %{
           parent: parent,
           leaf: leaf,
           story: story
         })}
      end

      then_ "ComponentSync resolved the deeply-nested leaf's parent_component_id to the registered ancestor, skipping the unregistered namespace",
            context do
        assert context.leaf,
               "expected MyContext.Thing.Leaf to be a registered Component after sync"

        assert context.leaf.parent_component_id == context.parent.id,
               "expected Thing.Leaf.parent_component_id (#{inspect(context.leaf.parent_component_id)}) to point at MyContext (#{context.parent.id}), proving find_nearest_ancestor skipped the unregistered `Thing` namespace"

        {:ok, context}
      end

      when_ "the agent calls get_next_requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
        {:ok, Map.put(context, :response_text, TaskResponseHelpers.response_text(response))}
      end

      then_ "MyContext.Thing.Leaf surfaces in the wave, proving priority cascaded through the namespace gap",
            context do
        text = context.response_text

        assert text =~ "entity_id=`#{context.leaf.id}`",
               "expected MyContext.Thing.Leaf to appear in the actionable wave — its priority must be inherited via the parent_component_id chain even though the intermediate `Thing` namespace has no Component record. If find_nearest_ancestor failed to skip the namespace gap, Leaf would either have nil parent_component_id (orphan, filtered by untethered_component?) or never appear at all. Response: #{text}"

        {:ok, context}
      end
    end
  end

  defp design_review_content(module) do
    """
    # #{module} Design Review

    ## Overview

    Reviewed the #{module} context with one schema descendant nested
    through an unregistered module-namespace gap. The architecture
    deliberately leaves the intermediate namespace as a pure
    module path with no Component record.

    ## Architecture

    - The context owns its child tree via parent_component_id
      derivation by find_nearest_ancestor, which traverses the dotted
      module name and skips unregistered intermediates.

    ## Integration

    - No cross-context integration points.

    ## Conclusion

    Ready for implementation. No outstanding action items.
    """
  end
end
