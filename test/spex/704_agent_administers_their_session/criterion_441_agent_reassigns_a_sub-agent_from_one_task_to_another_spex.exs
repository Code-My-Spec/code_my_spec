defmodule CodeMySpecSpex.Story704.Criterion6096Spex do
  @moduledoc """
  Story 704 — Agent administers their session
  Criterion 6096 — Agent reassigns a sub-agent from one task to another.

  Covers Rule 4's reassignment path: when the same `assign_subagent`
  is called with a sub-agent already on task A, the call atomically
  clears A's agent_id and sets B's agent_id.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.ComponentHelpers
  alias CodeMySpecSpex.HarnessHooks
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Agent reassigns a sub-agent from one task to another", criterion: 441 do
    scenario "assign_subagent clears the old assignment when moving to a new task" do
      given_ :synced_context_component

      given_ "a live harness serves the checkout", context do
        {:ok, HarnessHooks.ensure_live_harness(context)}
      end

      given_ "a sub-agent currently assigned to task A; an open task B with no agent_id",
             context do
        session_id = "spex-6096-#{System.unique_integer([:positive])}"
        agent_id = "mover-#{System.unique_integer([:positive])}"

        HarnessHooks.post_hook(context, "session-start", %{"session_id" => session_id})

        HarnessHooks.post_hook(context, "subagent-start", %{
          "session_id" => session_id,
          "agent_id" => agent_id,
          "agent_name" => "@mover"
        })

        frame = %Frame{assigns: %{current_scope: context.scope}}

        # Task A: agent claims implementation work
        _ =
          ToolLibrary.run(
            "start_task",
            %{
              requirement_name: "implementation_file",
              entity_type: "component",
              entity_id: to_string(context.component.id),
              session_id: session_id,
              agent_id: agent_id
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        # Task B belongs to a different component, with the same implementation requirement.
        other =
          ComponentHelpers.create(context.scope,
            type: "context",
            module_name: "OtherContext",
            name: "Other Context",
            description: "Another implementation task."
          )

        _ =
          ToolLibrary.run(
            "start_task",
            %{
              requirement_name: "implementation_file",
              entity_type: "component",
              entity_id: to_string(other.id),
              session_id: session_id
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        # Pull both task ids from list_tasks rather than reading the DB.
        list_resp =
          ToolLibrary.run(
            "list_tasks",
            %{session_id: session_id},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        list_text = TaskResponseHelpers.response_text(list_resp)

        task_a_id = task_id_for_requirement(list_text, context.component.module_name)
        task_b_id = task_id_for_requirement(list_text, other.module_name)

        {:ok,
         Map.merge(context, %{
           session_id: session_id,
           agent_id: agent_id,
           task_a_id: task_a_id,
           task_b_id: task_b_id
         })}
      end

      when_ "the agent calls assign_subagent with task B's id", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "assign_subagent",
            %{
              session_id: context.session_id,
              agent_id: context.agent_id,
              task_id: context.task_b_id
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, Map.put(context, :response_text, TaskResponseHelpers.response_text(response))}
      end

      then_ "list_tasks shows task B carrying the agent_id and task A unassigned",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "list_tasks",
            %{session_id: context.session_id},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        text = TaskResponseHelpers.response_text(response)

        row_a =
          text |> String.split("\n") |> Enum.find(&String.contains?(&1, context.task_a_id))

        row_b =
          text |> String.split("\n") |> Enum.find(&String.contains?(&1, context.task_b_id))

        assert row_b =~ "agent=#{context.agent_id}",
               "expected task B to carry the sub-agent's agent_id in list_tasks, got:\n#{row_b}"

        assert row_a =~ "unassigned",
               "expected task A to be unassigned in list_tasks (no agent_id), got:\n#{row_a}"

        {:ok, context}
      end
    end
  end

  defp task_id_for_requirement(list_text, requirement_name) do
    list_text
    |> String.split("\n")
    |> Enum.find(&String.contains?(&1, requirement_name))
    |> then(&Regex.run(~r/`([0-9a-f-]+)`/, &1))
    |> List.last()
  end
end
