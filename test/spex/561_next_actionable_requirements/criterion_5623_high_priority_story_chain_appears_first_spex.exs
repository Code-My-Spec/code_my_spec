defmodule CodeMySpecSpex.Story561.Criterion5623Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements
  Criterion 5623 — High-priority story's component chain appears in
  the actionable list before low-priority story's.

  Surface: get_next_requirement MCP tool. With two contexts synced —
  each linked to its own story but with different priority numbers —
  the actionable response must show the higher-priority story's
  component chain ahead of the lower-priority one.
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

  spex "Priority ordering surfaces the higher-priority story's context first" do
    scenario "high-priority context appears before low-priority context in the response" do
      given_ "two top-level contexts synced via the real /sync pipeline", context do
        env = context.environment

        Enum.each(
          [
            {"HighContext", :context, []},
            {"LowContext", :context, []}
          ],
          fn {module, type, deps} ->
            spec_content = Content.context_spec(module, type: Atom.to_string(type), dependencies: deps)
            :ok = Environments.write_file(env, Content.spec_path(module), spec_content)
            :ok = Environments.write_file(env, Content.impl_path(module), Content.impl_file(module))
          end
        )

        {:ok, sync_live, _html} = live(context.conn, "/projects/#{context.project.name}/sync")
        sync_live |> element("button[phx-click='sync']") |> render_click()

        high = Fixtures.get_component_by_module_name(context.scope, "HighContext")
        low = Fixtures.get_component_by_module_name(context.scope, "LowContext")

        {:ok, Map.merge(context, %{high_context: high, low_context: low})}
      end

      and_ "a high-priority story (1) is linked to HighContext and a low-priority story (5) to LowContext",
           context do
        high_story =
          StoryHelpers.create_and_link(context.scope, "HighContext",
            title: "High priority work",
            description: "As a user, I want to work on the urgent thing first.",
            acceptance_criteria: ["Urgent thing happens"],
            priority: 1
          )

        low_story =
          StoryHelpers.create_and_link(context.scope, "LowContext",
            title: "Low priority work",
            description: "As a user, I want this lower-priority thing eventually.",
            acceptance_criteria: ["Eventually thing happens"],
            priority: 5
          )

        {:ok, Map.merge(context, %{high_story: high_story, low_story: low_story})}
      end

      when_ "the agent calls get_next_requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
        {:ok, Map.put(context, :response_text, TaskResponseHelpers.response_text(response))}
      end

      then_ "the high-priority context appears before the low-priority context",
            context do
        high_id = context.high_context.id
        low_id = context.low_context.id

        high_pos = position_of(context.response_text, "entity_id=`#{high_id}`")
        low_pos = position_of(context.response_text, "entity_id=`#{low_id}`")

        cond do
          high_pos != nil and low_pos == nil ->
            # Orchestration grouping correctly scoped to high-priority context.
            :ok

          high_pos == nil and low_pos != nil ->
            flunk(
              "low-priority context appeared while high-priority context did not — priority sort violated. Response: #{context.response_text}"
            )

          high_pos != nil and low_pos != nil ->
            assert high_pos < low_pos,
                   "high-priority (pos #{high_pos}) must come before low-priority (pos #{low_pos}). Response: #{context.response_text}"

          true ->
            flunk(
              "neither context appeared in the actionable response — fixture didn't surface either chain. Response: #{context.response_text}"
            )
        end

        {:ok, context}
      end
    end
  end

  defp position_of(text, substring) do
    case :binary.match(text, substring) do
      {pos, _len} -> pos
      :nomatch -> nil
    end
  end
end
