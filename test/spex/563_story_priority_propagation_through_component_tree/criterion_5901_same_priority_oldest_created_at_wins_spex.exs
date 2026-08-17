defmodule CodeMySpecSpex.Story563.Criterion5901Spex do
  @moduledoc """
  Story 563 — Story Priority Propagation Through Component Tree
  Criterion 5901 — When two stories share the same priority and
  their actionable subgraphs are not edge-ordered against each
  other, the older story (earlier created_at) wins the tiebreak.

  Surface: get_next_requirement MCP tool. Two stories created in
  sequence with priority 1 each produce a response in which the
  older story's chain leads.
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

  spex "Same priority, oldest created_at wins" do
    scenario "older story's context leads when both stories share priority 1" do
      given_ "two contexts synced and linked to two priority-1 stories created in sequence",
             context do
        env = context.environment

        Enum.each(
          [{"FirstContext", []}, {"SecondContext", []}],
          fn {module, deps} ->
            :ok =
              Environments.write_file(
                env,
                Content.spec_path(module),
                Content.context_spec(module, type: "context", dependencies: deps)
              )

            :ok =
              Environments.write_file(env, Content.impl_path(module), Content.impl_file(module))
          end
        )

        {:ok, sync_live, _html} = live(context.conn, "/app/projects/#{context.project.id}/files")
        sync_live |> element("button[phx-click='sync']") |> render_click()

        first = Fixtures.get_component_by_module_name(context.scope, "FirstContext")
        second = Fixtures.get_component_by_module_name(context.scope, "SecondContext")

        # Created older, not created earlier. This separated the two with a
        # `Process.sleep(10)` and hoped the clock had moved — a guess about how
        # far apart two inserts land, and one that failed in a sweep when both
        # rows took the same timestamp, leaving the tie-break with nothing to
        # break the tie on (48924084).
        older =
          StoryHelpers.create_and_link(context.scope, "FirstContext",
            title: "First",
            description: "As a user, I want the older story to lead on tiebreak.",
            acceptance_criteria: ["First ships first"],
            priority: 1
          )

        Fixtures.age_story(context.scope, older.id, 60)

        StoryHelpers.create_and_link(context.scope, "SecondContext",
          title: "Second",
          description: "As a user, I want the newer story to wait.",
          acceptance_criteria: ["Second ships second"],
          priority: 1
        )

        {:ok, Map.merge(context, %{first: first, second: second})}
      end

      when_ "the agent calls get_next_requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
        {:ok, Map.put(context, :response_text, TaskResponseHelpers.response_text(response))}
      end

      then_ "the older story's context leads — newer is not the head", context do
        text = context.response_text
        first_pos = position_of(text, "entity_id=`#{context.first.id}`")
        second_pos = position_of(text, "entity_id=`#{context.second.id}`")

        verify_priority_order(
          {first_pos, second_pos},
          high_label: "first_pos",
          low_label: "second_pos",
          only_low_flunk:
            "newer story surfaced while older did not — created_at tiebreak violated. Response: #{text}",
          order_assert: "expected older (FirstContext) to lead newer. Response: #{text}",
          neither_flunk: "neither context surfaced. Response: #{text}"
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
