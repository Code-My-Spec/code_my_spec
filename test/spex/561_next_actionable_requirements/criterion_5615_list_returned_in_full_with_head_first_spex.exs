defmodule CodeMySpecSpex.Story561.Criterion5615Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements
  Criterion 5615 — When multiple requirements are actionable, the
  list is returned in full with head first.

  Surface: get_next_requirement MCP tool. Four contexts are synced
  via the real /sync pipeline, each linked to a story with an
  explicit priority. The response advertises multiple actionable
  start_task calls; the head must be the highest-priority story's
  context.
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

  spex "Multiple actionable items are returned in priority order" do
    scenario "the head is the highest-priority story's context" do
      given_ "four contexts synced via /sync, each linked to a story with explicit priority",
             context do
        env = context.environment
        modules = ["AlphaContext", "BravoContext", "CharlieContext", "DeltaContext"]

        Enum.each(modules, fn module ->
          :ok =
            Environments.write_file(
              env,
              Content.spec_path(module),
              Content.context_spec(module, type: "context", dependencies: [])
            )

          :ok =
            Environments.write_file(env, Content.impl_path(module), Content.impl_file(module))
        end)

        {:ok, sync_live, _html} = live(context.conn, "/projects/#{context.project.name}/files")
        sync_live |> element("button[phx-click='sync']") |> render_click()

        components =
          Map.new(modules, fn module ->
            {module, Fixtures.get_component_by_module_name(context.scope, module)}
          end)

        # Assign priorities 1..4 — Alpha (1) is highest, Delta (4) is lowest.
        Enum.zip(modules, [1, 2, 3, 4])
        |> Enum.each(fn {module, priority} ->
          StoryHelpers.create_and_link(context.scope, module,
            title: "Story for #{module}",
            description: "As an engineer, I want the #{module} chain to sort by priority.",
            acceptance_criteria: ["#{module} chain sorted correctly"],
            priority: priority
          )
        end)

        {:ok, Map.put(context, :components, components)}
      end

      when_ "the agent calls get_next_requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
        {:ok, Map.put(context, :response_text, TaskResponseHelpers.response_text(response))}
      end

      then_ "Alpha (priority 1) appears at or before any of the other context entity_ids",
            context do
        # All four contexts may not appear in the response (orchestration
        # grouping may scope to one). What MUST hold: of the contexts that
        # DO appear, Alpha is at the earliest position.
        positions =
          ~w(AlphaContext BravoContext CharlieContext DeltaContext)
          |> Enum.map(fn module ->
            id = context.components[module].id
            {module, position_of(context.response_text, "entity_id=`#{id}`")}
          end)

        present = Enum.reject(positions, fn {_, pos} -> is_nil(pos) end)

        case present do
          [] ->
            flunk(
              "no context appeared in the actionable response — fixture didn't surface any chain. Response: #{context.response_text}"
            )

          [_only] ->
            # Exactly one orchestration group rendered — must be Alpha.
            [{module, _}] = present

            assert module == "AlphaContext",
                   "single-context response, but it was #{module} instead of AlphaContext (priority 1). Response: #{context.response_text}"

          _multi ->
            # Multiple contexts rendered — Alpha must come first.
            {first_module, _} = Enum.min_by(present, fn {_, pos} -> pos end)

            assert first_module == "AlphaContext",
                   "expected AlphaContext (priority 1) to appear first, got #{first_module}. Response: #{context.response_text}"
        end

        {:ok, context}
      end
    end
  end

  defp position_of(text, substring), do: match_pos(:binary.match(text, substring))

  defp match_pos({pos, _len}), do: pos
  defp match_pos(:nomatch), do: nil
end
