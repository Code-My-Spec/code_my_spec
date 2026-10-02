defmodule CodeMySpecSpex.Story563.Criterion5902Spex do
  @moduledoc """
  Story 563 — Story Priority Propagation Through Component Tree
  Criterion 5902 — A component with no story link, no dependency-of
  relationship, and no parent-chain priority sorts last among
  parallel-eligible nodes — it does not lead the wave when
  priority-bearing components are also actionable.

  Surface: get_next_requirement MCP tool. A linked component and an
  orphan component are both actionable; the response leads with the
  linked component, not the orphan.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.ComponentGraphHelpers, only: [design!: 2]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.ComponentHelpers
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    {:ok, CodeMySpecSpex.ProjectStateFixtures.apply_project_kickoff(context)}
  end

  spex "Components with no inherited priority sort last", criterion: 225 do
    scenario "the linked priority-1 context leads, the orphan does not appear in the wave" do
      given_ "a priority-1 linked context and an orphan with no priority", context do
        design!(context, "LinkedContext")

        linked = Fixtures.get_component_by_module_name(context.scope, "LinkedContext")

        StoryHelpers.create_ready_and_link(context, "LinkedContext",
          title: "Linked story",
          description: "As a user, I want the linked component to lead.",
          acceptance_criteria: ["Linked ships"],
          priority: 1
        )

        orphan =
          ComponentHelpers.create(context.scope,
            type: "service",
            module_name: "OrphanContext",
            name: "Orphan Context",
            description: "An orphan with no story linkage."
          )

        {:ok, Map.merge(context, %{linked: linked, orphan: orphan})}
      end

      when_ "the agent calls get_next_requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
        {:ok, Map.put(context, :response_text, TaskResponseHelpers.response_text(response))}
      end

      then_ "the linked context leads — orphan is not the head", context do
        text = context.response_text
        linked_pos = position_of(text, "entity_id=`#{context.linked.id}`")
        orphan_pos = position_of(text, "entity_id=`#{context.orphan.id}`")

        verify_priority_order(
          {linked_pos, orphan_pos},
          high_label: "linked_pos",
          low_label: "orphan_pos",
          only_low_flunk:
            "orphan led the wave while the priority-1 linked component did not surface. Response: #{text}",
          order_assert:
            "expected linked (priority 1) to precede orphan (no priority). Response: #{text}",
          neither_flunk: "neither component appeared. Response: #{text}"
        )

        {:ok, context}
      end
    end
  end

  # Verifies ordering of two positions in a response text. Pattern-matched
  # rather than imperative branching so the spex stays declarative.
  defp verify_priority_order({high_pos, nil}, _opts) when not is_nil(high_pos), do: :ok

  defp verify_priority_order({nil, low_pos}, opts) when not is_nil(low_pos),
    do: flunk(opts[:only_low_flunk])

  defp verify_priority_order({high_pos, low_pos}, opts)
       when not is_nil(high_pos) and not is_nil(low_pos),
       do: assert(high_pos < low_pos, opts[:order_assert])

  defp verify_priority_order({nil, nil}, opts), do: flunk(opts[:neither_flunk])
  defp position_of(text, substring), do: match_pos(:binary.match(text, substring))

  defp match_pos({pos, _len}), do: pos
  defp match_pos(:nomatch), do: nil
end
