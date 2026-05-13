defmodule CodeMySpecSpex.Story563.Criterion5904Spex do
  @moduledoc """
  Story 563 — Story Priority Propagation Through Component Tree
  Criterion 5904 — A child component inherits its parent's priority
  via the parent_component_id chain. With a parent context linked to
  a priority-1 story and an unrelated low-priority context (with its
  own child at the same depth), the priority-1 cluster surfaces ahead
  of the low-priority leaf.

  Surface: get_next_requirement MCP tool. Mirrors 5903's
  dependency-spread inheritance test, but here the inheritance edge
  is parent_component_id (module nesting) rather than `depends_on`.

  Neither child is directly story-linked — their priority must come
  through their parent context's story linkage. That isolates the
  parent-chain propagation from any direct-link shortcut.

  ## Why this asserts on the child specifically

  The criterion's unique mechanism is `build_component_priority_map`'s
  parent-chain walk. If that branch is removed, the child has no
  priority entry and `untethered_component?` filters it out of
  `actionable_from` — so the child's `entity_id` would not appear in
  the response at all. Asserting `HighContext.Item.id` is present in
  the rendered text is the surface signal that the parent chain
  worked. (A weaker `parent OR child` assertion would still pass when
  parent chain is broken, because HighContext has its own direct link.)

  ## Why the heavy project-state fixturing

  Component-level requirements stay invisible in actionable until the
  serial project chain (project_setup → personas_complete →
  stories_exist → technical_strategy → architecture_designed → ...)
  has cleared. We use `ProjectStateFixtures.apply_project_kickoff/1`
  to satisfy all of those in one call. We then write per-context
  review files so each context's parent-scope review_valid is
  satisfied and the child-phase requirements (test_file, etc. on
  HighContext.Item and LowContext.Other) become the actionable
  frontier — the layer where parent-chain priority inheritance
  becomes visible.
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

  spex "Parent-chain inheritance propagates priority down" do
    scenario "child of priority-1 parent leads against unrelated low-priority child" do
      given_ "the project chain is past kickoff so component-level work is the frontier",
             context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ "HighContext (priority 1) and LowContext (priority 9), each with a schema child and review files",
             context do
        env = context.environment

        write_context_with_review(env, "HighContext", "HighContext.Item")
        write_schema_spec_only(env, "HighContext.Item")

        write_context_with_review(env, "LowContext", "LowContext.Other")
        write_schema_spec_only(env, "LowContext.Other")

        {:ok, sync_live, _html} = live(context.conn, "/projects/#{context.project.name}/files")
        sync_live |> element("button[phx-click='sync']") |> render_click()

        high = Fixtures.get_component_by_module_name(context.scope, "HighContext")
        high_child = Fixtures.get_component_by_module_name(context.scope, "HighContext.Item")
        low = Fixtures.get_component_by_module_name(context.scope, "LowContext")
        low_child = Fixtures.get_component_by_module_name(context.scope, "LowContext.Other")

        high_story =
          StoryHelpers.create_and_link(context.scope, "HighContext",
            title: "High priority parent",
            description: "As a user, I want the HighContext cluster shipped first.",
            acceptance_criteria: ["HighContext renders"],
            priority: 1
          )

        low_story =
          StoryHelpers.create_and_link(context.scope, "LowContext",
            title: "Low priority parent",
            description: "As a user, I want LowContext eventually.",
            acceptance_criteria: ["LowContext renders"],
            priority: 9
          )

        # Clear the full story-level chain on HighContext's story so
        # the wave can advance to component-level work for the priority-1
        # cluster. LowContext's story stays at basic-link state — its
        # story-level reqs (priority 9) sort after HighContext's
        # component-level reqs (priority 1) and stay out of the wave's
        # first orchestrated group.
        :ok =
          ProjectStateFixtures.apply_story_chain_complete(context, high_story,
            persona_id: context.persona_id,
            rule_statement: "HighContext renders the priority-1 cluster",
            happy_title: "User sees the priority-1 cluster work first",
            happy_body:
              "Given the user opens HighContext\nWhen they request work\nThen HighContext.Item leads",
            failure_title: "Untethered child is excluded",
            failure_body:
              "Given parent_component_id propagation is broken\nWhen the user requests work\nThen no HighContext.Item work appears"
          )

        {:ok,
         Map.merge(context, %{
           high: high,
           high_child: high_child,
           low: low,
           low_child: low_child,
           high_story: high_story,
           low_story: low_story
         })}
      end

      when_ "the agent calls get_next_requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
        {:ok, Map.put(context, :response_text, TaskResponseHelpers.response_text(response))}
      end

      then_ "HighContext.Item surfaces in the wave, proving parent-chain inheritance",
            context do
        text = context.response_text

        assert text =~ "entity_id=`#{context.high_child.id}`",
               "expected HighContext.Item to appear in the wave — its priority must be inherited via the parent_component_id chain, otherwise it would be untethered and excluded from actionable. Response: #{text}"

        {:ok, context}
      end

      and_ "the low-priority cluster does not eclipse the priority-1 wave",
           context do
        text = context.response_text

        refute text =~ "entity_id=`#{context.low_child.id}`",
               "LowContext.Other (priority-9 inherited via its own parent) should not appear while the priority-1 cluster has work. Response: #{text}"

        {:ok, context}
      end
    end
  end

  defp write_context_with_review(env, module, child_module) do
    module_path = module |> String.split(".") |> Enum.map_join("/", &Macro.underscore/1)

    :ok =
      Environments.write_file(
        env,
        Content.spec_path(module),
        Content.context_spec(module,
          type: "context",
          dependencies: [],
          children: [%{module: child_module, type: "schema"}]
        )
      )

    :ok = Environments.write_file(env, Content.impl_path(module), Content.impl_file(module))

    :ok =
      Environments.write_file(
        env,
        ".code_my_spec/spec/#{module_path}/design_review.md",
        design_review_content(module)
      )
  end

  # Schema child gets a spec file (so sync registers it as a component
  # with parent_component_id pointing at its parent context) but
  # intentionally NO implementation file. That leaves its child-phase
  # `implementation_file` requirement unsatisfied — the only way for the
  # child's entity_id to surface in the wave. With both spec AND impl
  # written, every requirement on the schema is satisfied and the wave
  # falls through to the parent's later phases instead.
  defp write_schema_spec_only(env, module) do
    :ok =
      Environments.write_file(
        env,
        Content.spec_path(module),
        Content.child_spec(module, type: "schema")
      )
  end

  defp design_review_content(module) do
    """
    # #{module} Design Review

    ## Overview

    Reviewed the #{module} context with one schema child. Sound
    architecture for a placeholder bounded context.

    ## Architecture

    - Separation of concerns is appropriate for the single-child
      context shape.
    - The schema child holds the persistence shape; the context
      exposes the public surface.

    ## Integration

    - The context has no integration points with other contexts.

    ## Conclusion

    Ready for implementation. No outstanding action items.
    """
  end
end
