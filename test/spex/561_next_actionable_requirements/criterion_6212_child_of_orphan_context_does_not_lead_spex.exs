defmodule CodeMySpecSpex.Story561.Criterion6212Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements
  Criterion 6212 — A child component of an orphan bounded context
  does not appear in the next-actionable wave.

  The architecture gate's orphan check (`ArchitectureChecker.orphans/1`)
  only flags context-shaped components; non-context children of an
  orphan context are not flagged there. They must still be kept out
  of `next_actionable` by the untethered filter — their parent has
  no inherited priority, so the priority-chain walk leaves them with
  no priority and `untethered_component?/2` drops them from the wave.

  Surface: get_next_requirement MCP tool. With one priority-1 linked
  context and an orphan context whose only child is a schema (no
  story link, no covered upstream dep), the response leads with the
  linked context and the orphan's child is not in the wave.
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

  spex "Child of an orphan bounded context is kept out of the wave" do
    scenario "priority-1 linked context leads; orphan's child schema is not surfaced" do
      given_ "a priority-1 linked context and an orphan context with a child schema", context do
        env = context.environment

        :ok =
          Environments.write_file(
            env,
            Content.spec_path("LinkedContext"),
            Content.context_spec("LinkedContext", type: "context", dependencies: [])
          )

        :ok =
          Environments.write_file(
            env,
            Content.impl_path("LinkedContext"),
            Content.impl_file("LinkedContext")
          )

        :ok =
          Environments.write_file(
            env,
            Content.spec_path("OrphanContext"),
            Content.context_spec("OrphanContext", type: "context", dependencies: [])
          )

        :ok =
          Environments.write_file(
            env,
            Content.impl_path("OrphanContext"),
            Content.impl_file("OrphanContext")
          )

        :ok =
          Environments.write_file(
            env,
            Content.spec_path("OrphanContext.Schema"),
            Content.child_spec("OrphanContext.Schema", type: "schema", dependencies: [])
          )

        :ok =
          Environments.write_file(
            env,
            Content.impl_path("OrphanContext.Schema"),
            Content.impl_file("OrphanContext.Schema")
          )

        {:ok, sync_live, _html} = live(context.conn, "/projects/#{context.project.name}/files")
        sync_live |> element("button[phx-click='sync']") |> render_click()

        linked = Fixtures.get_component_by_module_name(context.scope, "LinkedContext")
        orphan = Fixtures.get_component_by_module_name(context.scope, "OrphanContext")
        orphan_child = Fixtures.get_component_by_module_name(context.scope, "OrphanContext.Schema")

        StoryHelpers.create_and_link(context.scope, "LinkedContext",
          title: "Linked story",
          description: "As a user, I want the linked component to lead.",
          acceptance_criteria: ["Linked ships"],
          priority: 1
        )

        {:ok,
         Map.merge(context, %{
           linked: linked,
           orphan: orphan,
           orphan_child: orphan_child
         })}
      end

      when_ "the agent calls get_next_requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
        {:ok, Map.put(context, :response_text, TaskResponseHelpers.response_text(response))}
      end

      then_ "the orphan context's child schema is not in the wave", context do
        text = context.response_text

        refute text =~ "entity_id=`#{context.orphan_child.id}`",
               "child of orphan context should not appear in next_actionable. Response: #{text}"

        {:ok, context}
      end

      and_ "the orphan context itself is not in the wave", context do
        refute context.response_text =~ "entity_id=`#{context.orphan.id}`",
               "orphan context should not appear in next_actionable. Response: #{context.response_text}"

        {:ok, context}
      end
    end
  end
end
