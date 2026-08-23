defmodule CodeMySpecSpex.Story704.Criterion6098Spex do
  @moduledoc """
  Story 704 — Agent administers their session
  Criterion 6098 — `assign_subagent` for an unregistered agent_id is rejected.

  Covers Rule 4's failure path: calling `assign_subagent` with an
  `agent_id` that doesn't appear in the session's `registered_subagents`
  returns an error and does not change any Task's `agent_id`.
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

  spex "assign_subagent for an unregistered agent_id is rejected" do
    scenario "the response is an error and no Task is mutated" do
      given_ :synced_context_component

      given_ "a session with one open task and NO registered sub-agents", context do
        session_id = "spex-6098-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post(~p"/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _, _} =
          StartTask.execute(
            %{
              requirement_name: "spec_file",
              entity_type: "component",
              entity_id: to_string(context.component.id),
              session_id: session_id
            },
            frame
          )

        {:reply, list_resp, _frame} =
          ListTasks.execute(%{session_id: session_id, status: "active"}, frame)

        [_, task_id] =
          list_resp
          |> TaskResponseHelpers.response_text()
          |> then(&Regex.run(~r/`([0-9a-f-]+)`/, &1))

        {:ok, Map.merge(context, %{session_id: session_id, task_id: task_id})}
      end

      when_ "the agent calls assign_subagent with an unregistered agent_id", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        unknown_agent = "unknown-#{System.unique_integer([:positive])}"

        {:reply, response, _frame} =
          AssignSubagent.execute(
            %{
              session_id: context.session_id,
              agent_id: unknown_agent,
              task_id: context.task_id
            },
            frame
          )

        {:ok,
         Map.merge(context, %{
           unknown_agent: unknown_agent,
           response: response,
           response_text: TaskResponseHelpers.response_text(response)
         })}
      end

      then_ "the response is an error naming the unknown agent_id", context do
        assert context.response.isError,
               "expected isError to be true, got: #{inspect(context.response)}"

        assert context.response_text =~ context.unknown_agent,
               "expected the error to name the unknown agent_id, got: #{context.response_text}"

        {:ok, context}
      end

      and_ "no Task in list_tasks carries the unknown agent_id", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ListTasks.execute(%{session_id: context.session_id}, frame)

        text = TaskResponseHelpers.response_text(response)

        # The target task's row should still show `unassigned`
        # (no agent_id ever landed) — and certainly not the unknown id.
        refute text =~ "agent=#{context.unknown_agent}",
               "expected no task to carry the unknown agent_id, got:\n#{text}"

        row =
          text |> String.split("\n") |> Enum.find(&String.contains?(&1, context.task_id))

        assert row =~ "unassigned",
               "expected the target task to remain unassigned, got row:\n#{row}"

        {:ok, context}
      end
    end
  end
end
