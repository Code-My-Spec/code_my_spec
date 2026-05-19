defmodule CodeMySpecSpex.Story563.Criterion5900Spex do
  @moduledoc """
  Story 563 — Story Priority Propagation Through Component Tree
  Criterion 5900 — Among parallel-eligible nodes that the graph does
  not order via edges, the wave is taken from the story with the
  lower priority number first; higher-priority numbers are queued
  behind.

  Surface: get_next_requirement MCP tool. Two unrelated stories with
  priorities 1 and 5 produce a response in which only the priority-1
  story's chain leads.
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

  spex "Lower priority number leads" do
    scenario "the priority-1 story's context appears, the priority-5 story's does not lead" do
      given_ "two unrelated contexts synced, each linked to a story with distinct priority",
             context do
        env = context.environment

        Enum.each(
          [{"UrgentContext", []}, {"LaterContext", []}],
          fn {module, deps} ->
            spec = Content.context_spec(module, type: "context", dependencies: deps)
            :ok = Environments.write_file(env, Content.spec_path(module), spec)
            :ok = Environments.write_file(env, Content.impl_path(module), Content.impl_file(module))
          end
        )

        {:ok, sync_live, _html} = live(context.conn, "/projects/#{context.project.name}/files")
        sync_live |> element("button[phx-click='sync']") |> render_click()

        urgent = Fixtures.get_component_by_module_name(context.scope, "UrgentContext")
        later = Fixtures.get_component_by_module_name(context.scope, "LaterContext")

        StoryHelpers.create_and_link(context.scope, "UrgentContext",
          title: "Urgent",
          description: "As a user, I want urgent things first.",
          acceptance_criteria: ["Urgent ships"],
          priority: 1
        )

        StoryHelpers.create_and_link(context.scope, "LaterContext",
          title: "Later",
          description: "As a user, I want later things later.",
          acceptance_criteria: ["Later ships"],
          priority: 5
        )

        {:ok, Map.merge(context, %{urgent: urgent, later: later})}
      end

      when_ "the agent calls get_next_requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
        {:ok, Map.put(context, :response_text, TaskResponseHelpers.response_text(response))}
      end

      then_ "the priority-1 context leads — the priority-5 context is not the head", context do
        text = context.response_text
        urgent_pos = position_of(text, "entity_id=`#{context.urgent.id}`")
        later_pos = position_of(text, "entity_id=`#{context.later.id}`")

        verify_priority_order(
          {urgent_pos, later_pos},
          high_label: "urgent_pos",
          low_label: "later_pos",
          only_low_flunk: "later (priority 5) appeared while urgent (priority 1) did not — sort violated. Response: #{text}",
          order_assert: "expected urgent before later. Response: #{text}",
          neither_flunk: "neither context appeared. Response: #{text}"
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
