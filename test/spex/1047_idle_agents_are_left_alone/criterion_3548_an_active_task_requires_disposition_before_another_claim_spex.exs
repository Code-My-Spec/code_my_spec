defmodule CodeMySpecSpex.Story1047.Criterion3548Spex do
  @moduledoc """
  Story 1047 — Idle agents are left alone.
  Criterion 3548 — An active task prevents another turn request until it
  is explicitly completed, blocked, or cancelled.

  The scenario's claim surface is start_task: another claim must be refused
  without silently replacing or cancelling the agent's existing task.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.McpServers.Tasks.Tools.ListTasks
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An active task must be dispositioned before another is claimed" do
    scenario "A second claim is refused and the first task remains active" do
      given_ :synced_context_component
      given_ :story_linked_to_component

      given_ "a coding agent has claimed a task", context do
        agent = Fixtures.running_agent(context.scope, role: "coding")
        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}}
        {:reply, graph_response, _} = GetNextRequirement.execute(%{}, frame)
        refute graph_response.isError, response_text(graph_response)

        {:reply, first, _} =
          StartTask.execute(
            %{
              requirement_name: "implementation_file",
              entity_type: "component",
              entity_id: to_string(context.component.id)
            },
            frame
          )

        refute first.isError, response_text(first)
        {:reply, tasks, _} = ListTasks.execute(%{status: "active"}, frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) =~ "# Tasks (1)"
        assert response_text(tasks) =~ "**implementation_file**"

        {:ok, Map.merge(context, %{agent_frame: frame, tasks_before: response_text(tasks)})}
      end

      when_ "it attempts to claim a different requirement without disposing of the first",
            context do
        # A story requirement, because a component now has exactly one. This
        # claimed `implementation_file` on the same component when components
        # carried `spec_file`, `test_file` and `review_file` too, and
        # `5662b2f6e` simplified them to implementation work alone — after
        # which "a different requirement" and "the one already held" were the
        # same call, and `start_task` answered it as the re-entry it looked
        # like rather than as the second claim this criterion is about.
        {:reply, response, _} =
          StartTask.execute(
            %{
              requirement_name: "three_amigos_complete",
              entity_type: "story",
              entity_id: to_string(context.story.id)
            },
            context.agent_frame
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the tool requires completion, blocking, or cancellation with no force escape",
            context do
        assert context.response.isError, response_text(context.response)
        text = context.response |> response_text() |> String.downcase()
        assert text =~ "active task"
        assert text =~ "complet"
        assert text =~ "block"
        assert text =~ "cancel"
        refute text =~ "force"
        {:ok, context}
      end

      then_ "the existing task is still the only active task", context do
        {:reply, tasks, _} = ListTasks.execute(%{status: "active"}, context.agent_frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) == context.tasks_before
        {:ok, context}
      end
    end
  end
end
