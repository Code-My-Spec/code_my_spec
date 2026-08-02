defmodule CodeMySpecSpex.Story561.Criterion5816Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements
  Criterion 5816 — An orphan component with no inherited priority
  does not lead the wave when a priority-1 component is also
  actionable. Orphans surface only after all priority-bearing work
  is queued.

  Surface: get_next_requirement MCP tool. With one priority-1 linked
  context and one orphan component both eligible, the response leads
  with the priority context — the orphan is not the head.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.ComponentHelpers
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.GraphContentFixtures, as: Content
  alias CodeMySpecSpex.StoryHelpers
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Orphan does not lead when priority-bearing work is actionable" do
    scenario "the linked priority-1 context wins; the orphan is not the head" do
      given_ "a priority-1 linked context and an orphan with no priority", context do
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

        {:ok, sync_live, _html} = live(context.conn, "/app/projects/#{context.project.name}/files")
        sync_live |> element("button[phx-click='sync']") |> render_click()

        linked = Fixtures.get_component_by_module_name(context.scope, "LinkedContext")

        StoryHelpers.create_and_link(context.scope, "LinkedContext",
          title: "Linked story",
          description: "As a user, I want the linked component to lead.",
          acceptance_criteria: ["Linked ships"],
          priority: 1
        )

        orphan =
          ComponentHelpers.create(context.scope,
            type: "context",
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

      then_ "the orphan is not the head of the wave", context do
        text = context.response_text

        refute text =~ "entity_id=`#{context.orphan.id}`",
               "orphan should not lead when priority work is actionable. Response: #{text}"

        {:ok, context}
      end

      and_ "the priority-1 linked context is in the response", context do
        assert context.response_text =~ "entity_id=`#{context.linked.id}`",
               "expected the priority-1 linked context to surface. Response: #{context.response_text}"

        {:ok, context}
      end
    end
  end
end
