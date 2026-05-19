defmodule CodeMySpecSpex.Story563.Criterion5906Spex do
  @moduledoc """
  Story 563 — Story Priority Propagation Through Component Tree
  Criterion 5906 — A component linked to no story sorts after all
  story-linked components.

  Surface: get_next_requirement MCP tool. Two contexts are written
  to the in-memory environment via the real /sync pipeline — one
  linked to a story, one not. The orchestration grouping must
  scope to the linked context (it sorts first by priority + link
  rank), and the orphan must not appear ahead of the linked one.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.GraphContentFixtures, as: Content
  alias CodeMySpecSpex.StoryHelpers
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Story-linked contexts sort before orphan contexts" do
    scenario "the orchestration group scopes to the story-linked context, not the orphan" do
      given_ "two contexts synced via the real /sync pipeline", context do
        env = context.environment

        Enum.each(["LinkedContext", "OrphanContext"], fn module ->
          :ok =
            Environments.write_file(
              env,
              Content.spec_path(module),
              Content.context_spec(module, type: "context", dependencies: [])
            )

          :ok =
            Environments.write_file(
              env,
              Content.impl_path(module),
              Content.impl_file(module)
            )
        end)

        {:ok, sync_live, _html} = live(context.conn, "/projects/#{context.project.name}/files")
        sync_live |> element("button[phx-click='sync']") |> render_click()

        linked = Fixtures.get_component_by_module_name(context.scope, "LinkedContext")
        orphan = Fixtures.get_component_by_module_name(context.scope, "OrphanContext")

        {:ok, Map.merge(context, %{linked: linked, orphan: orphan})}
      end

      and_ "a story is linked to LinkedContext (with explicit priority 1)", context do
        story =
          StoryHelpers.create_and_link(context.scope, "LinkedContext",
            title: "Linked context work",
            description: "As an engineer, I want the linked context to take precedence.",
            acceptance_criteria: ["LinkedContext receives the next dispatch"],
            priority: 1
          )

        {:ok, Map.put(context, :linked_story, story)}
      end

      when_ "the agent calls get_next_requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
        {:ok, Map.put(context, :response_text, TaskResponseHelpers.response_text(response))}
      end

      then_ "the linked context appears in the response and the orphan does not eclipse it",
            context do
        linked_id = context.linked.id
        orphan_id = context.orphan.id

        linked_pos = position_of(context.response_text, "entity_id=`#{linked_id}`")
        orphan_pos = position_of(context.response_text, "entity_id=`#{orphan_id}`")

        verify_priority_order(
          {linked_pos, orphan_pos},
          high_label: "linked_pos",
          low_label: "orphan_pos",
          only_low_flunk:
            "orphan-only response: priority sort favored unlinked over linked. Response: #{context.response_text}",
          order_assert:
            "linked context (pos #{linked_pos}) must appear before orphan (pos #{orphan_pos}). Response: #{context.response_text}",
          neither_flunk:
            "neither linked nor orphan appeared in the actionable response. Response: #{context.response_text}"
        )

        {:ok, context}
      end
    end
  end

  # Verifies ordering of two positions in a response text.
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
