defmodule CodeMySpecSpex.Story704.Criterion6095Spex do
  @moduledoc """
  Story 704 — Agent administers their session
  Criterion 6095 — Agent assigns an idle sub-agent to an open task.

  Covers Rule 4's primary happy path: `assign_subagent` sets
  `Task.agent_id` on the target task.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.HarnessHooks
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Agent assigns an idle sub-agent to an open task", criterion: 440 do
    scenario "assign_subagent sets Task.agent_id" do
      given_ :synced_context_component

      given_ "a live harness serves the checkout", context do
        {:ok, HarnessHooks.ensure_live_harness(context)}
      end

      given_ "a session with one registered idle sub-agent and one open task with no agent_id",
             context do
        session_id = "spex-6095-#{System.unique_integer([:positive])}"
        agent_id = "idle-#{System.unique_integer([:positive])}"

        HarnessHooks.post_hook(context, "session-start", %{"session_id" => session_id})

        HarnessHooks.post_hook(context, "subagent-start", %{
          "session_id" => session_id,
          "agent_id" => agent_id,
          "agent_name" => "@idle"
        })

        # Create an open task via start_task (no agent_id assignment yet)
        frame = %Frame{assigns: %{current_scope: context.scope}}

        _resp =
          ToolLibrary.run(
            "start_task",
            %{
              requirement_name: "implementation_file",
              entity_type: "component",
              entity_id: to_string(context.component.id),
              session_id: session_id
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        # Pull the new task's id off the public list_tasks surface
        # rather than reading the DB.
        list_resp =
          ToolLibrary.run(
            "list_tasks",
            %{session_id: session_id, status: "active"},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        [_, task_id] =
          list_resp
          |> TaskResponseHelpers.response_text()
          |> then(&Regex.run(~r/`([0-9a-f-]+)`/, &1))

        {:ok,
         Map.merge(context, %{
           session_id: session_id,
           agent_id: agent_id,
           task_id: task_id
         })}
      end

      when_ "the agent calls assign_subagent", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "assign_subagent",
            %{
              session_id: context.session_id,
              agent_id: context.agent_id,
              task_id: context.task_id
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, Map.put(context, :response_text, TaskResponseHelpers.response_text(response))}
      end

      then_ "list_tasks shows the target task carrying the sub-agent's agent_id",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "list_tasks",
            %{session_id: context.session_id},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        text = TaskResponseHelpers.response_text(response)

        row =
          text
          |> String.split("\n")
          |> Enum.find(&String.contains?(&1, context.task_id))

        assert row =~ "agent=#{context.agent_id}",
               "expected list_tasks row for the target task to show agent=#{context.agent_id}, got:\n#{row}"

        {:ok, context}
      end

      and_ "the response confirms the assignment with both identities echoed back",
           context do
        text = context.response_text

        assert text =~ context.agent_id,
               "expected response to echo agent_id, got:\n#{text}"

        assert text =~ context.task_id,
               "expected response to echo task_id, got:\n#{text}"

        {:ok, context}
      end
    end
  end
end
