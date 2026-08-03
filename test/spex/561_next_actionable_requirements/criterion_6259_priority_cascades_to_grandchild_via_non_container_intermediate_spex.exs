defmodule CodeMySpecSpex.Story561.Criterion6259Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements
  Criterion 6259 — Linked context priority cascades to a grandchild
  via a non-container intermediate.

  Covers Rule f24fa177: "Priority cascades down `parent_component_id`
  chains to all descendants regardless of intermediate parent type."

  The "regardless of intermediate parent type" clause is the load-
  bearing one. Container types (context, coordination_context,
  live_context) own children explicitly; non-container types
  (behaviour, schema, module, etc.) are intermediates that happen to
  appear in the module namespace between a linked context and a
  deeper leaf. The chain walk must traverse them without stopping.

  ## Scenario shape

  - HighContext (priority-1 story-linked, type: context)
    └─ HighContext.Connector (type: behaviour — non-container)
        └─ HighContext.Connector.Item (type: schema — leaf)

  - LowContext (priority-9 story-linked, type: context)
    └─ LowContext.Other (type: schema)

  HighContext.Connector.Item has a valid spec but no implementation
  file — its implementation_file requirement is the unsatisfied
  frontier. Its priority must come through the parent_component_id
  chain: Item → Connector → HighContext. Without the chain walking
  through the non-container Connector, Item would be untethered and
  the actionability filter would drop it.

  ## Why the heavy fixturing

  Component-level requirements stay invisible in actionable until the
  serial project chain has cleared. We use
  `ProjectStateFixtures.apply_project_kickoff/1` for the project layer
  and `apply_story_chain_complete/3` to clear HighContext's story
  chain. LowContext's story stays at basic-link state — its
  story-level reqs (priority 9) sort after HighContext's
  component-level reqs (priority 1).
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.GraphAssertions
  alias CodeMySpecSpex.GraphContentFixtures, as: Content
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecSpex.StoryHelpers

  @actionable_color "#f5f5f7"
  @blocked_color "#fde047"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Priority cascades to a grandchild via a non-container intermediate" do
    scenario "grandchild under a behaviour intermediate inherits priority from the linked context" do
      given_ "the project chain is past kickoff so component-level work is the frontier",
             context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ "HighContext (priority 1) → Connector (behaviour) → Item (schema, no impl); LowContext (priority 9) → Other (schema, no impl)",
             context do
        env = context.environment

        # HighContext: top-level container, story-linked at priority 1
        write_context_with_review(env, "HighContext", ["HighContext.Connector"])

        # Non-container intermediate (behaviour-typed). Has a spec so it
        # gets a Component row; the chain walk must traverse it without
        # stopping.
        :ok =
          Environments.write_file(
            env,
            Content.spec_path("HighContext.Connector"),
            Content.child_spec("HighContext.Connector", type: "behaviour")
          )

        :ok =
          Environments.write_file(
            env,
            Content.impl_path("HighContext.Connector"),
            Content.impl_file("HighContext.Connector")
          )

        # Grandchild: schema leaf, spec only (no impl) so its
        # implementation_file requirement is the unsatisfied frontier.
        :ok =
          Environments.write_file(
            env,
            Content.spec_path("HighContext.Connector.Item"),
            Content.child_spec("HighContext.Connector.Item", type: "schema")
          )

        # Low-priority counter-example
        write_context_with_review(env, "LowContext", ["LowContext.Other"])

        :ok =
          Environments.write_file(
            env,
            Content.spec_path("LowContext.Other"),
            Content.child_spec("LowContext.Other", type: "schema")
          )

        {:ok, sync_live, _html} = live(context.conn, "/app/projects/#{context.project.id}/files")
        sync_live |> element("button[phx-click='sync']") |> render_click()

        high = Fixtures.get_component_by_module_name(context.scope, "HighContext")
        connector = Fixtures.get_component_by_module_name(context.scope, "HighContext.Connector")
        item = Fixtures.get_component_by_module_name(context.scope, "HighContext.Connector.Item")
        low = Fixtures.get_component_by_module_name(context.scope, "LowContext")
        low_other = Fixtures.get_component_by_module_name(context.scope, "LowContext.Other")

        high_story =
          StoryHelpers.create_and_link(context.scope, "HighContext",
            title: "HighContext priority-1 cluster",
            description: "As a user, I want the HighContext cluster shipped first.",
            acceptance_criteria: ["HighContext renders"],
            priority: 1
          )

        _low_story =
          StoryHelpers.create_and_link(context.scope, "LowContext",
            title: "LowContext priority-9 cluster",
            description: "As a user, I want LowContext eventually.",
            acceptance_criteria: ["LowContext renders"],
            priority: 9
          )

        :ok =
          ProjectStateFixtures.apply_story_chain_complete(context, high_story,
            persona_id: context.persona_id,
            rule_statement: "HighContext drives the priority-1 cluster",
            happy_title: "User sees the priority-1 cluster work first",
            happy_body:
              "Given the user opens HighContext\nWhen they request work\nThen Connector.Item leads",
            failure_title: "Untethered grandchild is excluded",
            failure_body:
              "Given parent chain stops at the non-container intermediate\nWhen the user requests work\nThen no Connector.Item work appears"
          )

        {:ok,
         Map.merge(context, %{
           high: high,
           connector: connector,
           item: item,
           low: low,
           low_other: low_other
         })}
      end

      then_ "the grandchild's parent chain reaches HighContext through the behaviour intermediate",
            context do
        assert context.item,
               "expected HighContext.Connector.Item to be a registered Component after sync"

        assert context.item.parent_component_id == context.connector.id,
               "expected Item.parent_component_id to point at Connector (the immediate non-container parent)"

        assert context.connector.parent_component_id == context.high.id,
               "expected Connector.parent_component_id to point at HighContext, completing the chain that priority walks"

        {:ok, context}
      end

      when_ "the engineer opens the requirements graph", context do
        {:ok, _live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/requirements/graph?preload=true")

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "Connector.Item's nodes render in the actionable color — not as untethered/orphan",
            context do
        # The actionability filter (`actionable_from` in RequirementGraph)
        # drops untethered components — ones with no priority inheritance.
        # If parent-chain priority can't walk through the non-container
        # Connector parent, Item is untethered and its nodes never render
        # in the actionable color. Verifying any of Item's nodes shows
        # actionable color is direct evidence the chain walked through.
        item_nodes =
          Enum.filter(context.graph["nodes"], fn n ->
            n["attributes"]["entity_id"] == context.item.id
          end)

        assert item_nodes != [],
               "expected Connector.Item's nodes to be present in the rendered graph; missing entirely suggests the projector dropped it"

        actionable_or_blocked =
          Enum.filter(item_nodes, fn n ->
            n["attributes"]["color"] in [@actionable_color, @blocked_color]
          end)

        assert actionable_or_blocked != [],
               "expected at least one of Connector.Item's nodes to render in actionable (#{@actionable_color}) or blocked (#{@blocked_color}) color — both prove priority was inherited through the non-container Connector parent. Untethered components are dropped from the priority map entirely and would never render in these colors. Got: #{inspect(Enum.map(item_nodes, &{&1["attributes"]["name"], &1["attributes"]["color"]}))}"

        {:ok, context}
      end
    end
  end

  defp write_context_with_review(env, module, child_modules) do
    module_path = module |> String.split(".") |> Enum.map_join("/", &Macro.underscore/1)
    children = Enum.map(child_modules, &%{module: &1, type: "schema"})

    :ok =
      Environments.write_file(
        env,
        Content.spec_path(module),
        Content.context_spec(module, type: "context", dependencies: [], children: children)
      )

    :ok = Environments.write_file(env, Content.impl_path(module), Content.impl_file(module))

    :ok =
      Environments.write_file(
        env,
        ".code_my_spec/spec/#{module_path}/design_review.md",
        design_review_content(module)
      )
  end

  defp design_review_content(module) do
    """
    # #{module} Design Review

    ## Overview

    Reviewed the #{module} context with its child tree. The
    architecture passes a non-container intermediate between the
    context and a leaf schema — exactly the shape that exercises
    the parent-chain priority walk.

    ## Architecture

    - Container context owns the public surface.
    - Non-container intermediate provides the behaviour contract.
    - Schema leaf holds the persistence shape.

    ## Integration

    - No cross-context integration points.

    ## Conclusion

    Ready for implementation. No outstanding action items.
    """
  end
end
