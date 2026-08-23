defmodule CodeMySpecSpex.Story704.Criterion6096Spex do
  @moduledoc """
  Story 704 — Agent administers their session
  Criterion 6096 — Agent reassigns a sub-agent from one task to another.

  Covers Rule 4's reassignment path: when the same `assign_subagent`
  is called with a sub-agent already on task A, the call atomically
  clears A's agent_id and sets B's agent_id.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.AssignSubagent
  alias CodeMySpec.McpServers.Tasks.Tools.ListTasks
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Agent reassigns a sub-agent from one task to another" do
    scenario "assign_subagent clears the old assignment when moving to a new task" do
      given_ :synced_context_component

      given_ "a sub-agent currently assigned to task A; an open task B with no agent_id",
             context do
        session_id = "spex-6096-#{System.unique_integer([:positive])}"
        agent_id = "mover-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post(~p"/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post(~p"/api/hooks/subagent-start", %{
          "session_id" => session_id,
          "agent_id" => agent_id,
          "agent_name" => "@mover"
        })
        |> Phoenix.ConnTest.json_response(200)

        frame = %Frame{assigns: %{current_scope: context.scope}}

        # Task A: agent claims spec_file
        {:reply, _, _} =
          StartTask.execute(
            %{
              requirement_name: "spec_file",
              entity_type: "component",
              entity_id: to_string(context.component.id),
              session_id: session_id,
              agent_id: agent_id
            },
            frame
          )

        # Task B: open (no agent_id) — start it for the same component
        # but a different requirement so they share an entity
        {:reply, _, _} =
          StartTask.execute(
            %{
              requirement_name: "implementation_file",
              entity_type: "component",
              entity_id: to_string(context.component.id),
              session_id: session_id
            },
            frame
          )

        # Pull both task ids from list_tasks rather than reading the DB.
        {:reply, list_resp, _frame} =
          ListTasks.execute(%{session_id: session_id}, frame)

        list_text = TaskResponseHelpers.response_text(list_resp)

        task_a_id = task_id_for_requirement(list_text, "spec_file")
        task_b_id = task_id_for_requirement(list_text, "implementation_file")

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

        {:reply, response, _frame} =
          AssignSubagent.execute(
            %{
              session_id: context.session_id,
              agent_id: context.agent_id,
              task_id: context.task_b_id
            },
            frame
          )

        {:ok, Map.put(context, :response_text, TaskResponseHelpers.response_text(response))}
      end

      then_ "list_tasks shows task B carrying the agent_id and task A unassigned",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ListTasks.execute(%{session_id: context.session_id}, frame)

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
