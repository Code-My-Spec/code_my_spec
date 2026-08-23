defmodule CodeMySpecSpex.Story704.Criterion6097Spex do
  @moduledoc """
  Story 704 — Agent administers their session
  Criterion 6097 — Agent cancels a stuck task to unblock the loop.

  Covers Rule 4's `cancel_task` path: an open task transitions to
  `:cancelled` without going through `evaluate_task`, and subsequent
  reads do not surface it as in-flight.

  Both assertions are observed through public agent surfaces:
  - `list_tasks` (status=active filter) — the cancelled task is absent
  - `list_tasks` (no filter) — the task appears with `:cancelled` status
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.CancelTask
  alias CodeMySpec.McpServers.Tasks.Tools.ListTasks
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Agent cancels a stuck task to unblock the loop" do
    scenario "cancel_task transitions task to :cancelled and removes it from active queries" do
      given_ :synced_context_component

      given_ "a session with one open task", context do
        session_id = "spex-6097-#{System.unique_integer([:positive])}"

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

        # Capture the new task's id via the public list_tasks surface
        # rather than reaching into Sessions directly.
        {:reply, list_resp, _frame} =
          ListTasks.execute(%{session_id: session_id, status: "active"}, frame)

        list_text = TaskResponseHelpers.response_text(list_resp)
        [_, task_id] = Regex.run(~r/`([0-9a-f-]+)`/, list_text)

        {:ok, Map.merge(context, %{session_id: session_id, task_id: task_id})}
      end

      when_ "the agent calls cancel_task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          CancelTask.execute(
            %{session_id: context.session_id, task_id: context.task_id},
            frame
          )

        refute response.isError, "expected cancel_task to succeed"
        {:ok, context}
      end

      then_ "the cancelled task no longer appears in active task queries", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ListTasks.execute(%{session_id: context.session_id, status: "active"}, frame)

        text = TaskResponseHelpers.response_text(response)

        refute text =~ context.task_id,
               "expected cancelled task #{context.task_id} to be absent from list_tasks(status=active), got:\n#{text}"

        {:ok, context}
      end

      and_ "the task itself is visible with :cancelled status in an unfiltered listing",
           context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ListTasks.execute(%{session_id: context.session_id}, frame)

        text = TaskResponseHelpers.response_text(response)

        assert text =~ context.task_id,
               "expected cancelled task to appear in unfiltered listing, got:\n#{text}"

        assert text =~ "cancelled",
               "expected `cancelled` status in the listing, got:\n#{text}"

        {:ok, context}
      end
    end
  end
end
