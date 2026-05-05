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

            :ok = Environments.write_file(env, Content.impl_path(module), Content.impl_file(module))
          end
        )

        {:ok, sync_live, _html} = live(context.conn, "/projects/#{context.project.name}/sync")
        sync_live |> element("button[phx-click='sync']") |> render_click()

        first = Fixtures.get_component_by_module_name(context.scope, "FirstContext")
        second = Fixtures.get_component_by_module_name(context.scope, "SecondContext")

        # Create in deterministic order so the older one is unambiguous.
        StoryHelpers.create_and_link(context.scope, "FirstContext",
          title: "First",
          description: "As a user, I want the older story to lead on tiebreak.",
          acceptance_criteria: ["First ships first"],
          priority: 1
        )

        # Tiny sleep to guarantee distinct timestamps. created_at resolves at
        # microsecond precision, but explicit ordering avoids fixture flake.
        Process.sleep(10)

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

        cond do
          first_pos != nil and second_pos == nil ->
            :ok

          first_pos == nil and second_pos != nil ->
            flunk(
              "newer story surfaced while older did not — created_at tiebreak violated. Response: #{text}"
            )

          first_pos != nil and second_pos != nil ->
            assert first_pos < second_pos,
                   "expected older (FirstContext) to lead newer. Response: #{text}"

          true ->
            flunk("neither context surfaced. Response: #{text}")
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
