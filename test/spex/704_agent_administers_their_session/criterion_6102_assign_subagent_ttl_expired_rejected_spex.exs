defmodule CodeMySpecSpex.Story704.Criterion6102Spex do
  @moduledoc """
  Story 704 — Agent administers their session
  Criterion 6102 — `assign_subagent` for a TTL-expired registration is
  rejected the same as an unknown agent_id.

  Covers Rule 4's intersection with Rule 2 (TTL pruning): once a
  sub-agent's `last_heartbeat_at` is older than the configured TTL,
  it shouldn't appear "registered" to admin tools. `assign_subagent`
  must reject the assignment — the agent is effectively dead even if
  the row is still in the JSONB array pending lazy prune.

  Without this rejection, the agent could believe it had successfully
  assigned a task to a sub-agent that no `list_session_subagents`
  caller can see — divergent truth.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.AssignSubagent
  alias CodeMySpec.McpServers.Tasks.Tools.ListTasks
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "assign_subagent for a TTL-expired registration is rejected" do
    scenario "the response is an error and no task carries the expired agent_id" do
      given_ :synced_context_component

      given_ "a session, one open task, and one TTL-expired sub-agent registration",
             context do
        session_id = "spex-6102-#{System.unique_integer([:positive])}"
        agent_id = "stale-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post(~p"/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        # Seed a sub-agent with a heartbeat 30 minutes ago — well past
        # the 10-minute default TTL.
        {:ok, _session} =
          Fixtures.register_subagent_with_heartbeat(context.scope, session_id, %{
            agent_id: agent_id,
            agent_name: "@stale",
            last_heartbeat_at:
              DateTime.utc_now()
              |> DateTime.add(-30 * 60, :second)
              |> DateTime.truncate(:second)
          })

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

        {:ok,
         Map.merge(context, %{
           session_id: session_id,
           agent_id: agent_id,
           task_id: task_id
         })}
      end

      when_ "the agent calls assign_subagent with the TTL-expired agent_id", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          AssignSubagent.execute(
            %{
              session_id: context.session_id,
              agent_id: context.agent_id,
              task_id: context.task_id
            },
            frame
          )

        {:ok,
         Map.merge(context, %{
           response: response,
           response_text: TaskResponseHelpers.response_text(response)
         })}
      end

      then_ "the response is an error naming the (now-expired) agent_id", context do
        assert context.response.isError,
               "expected isError to be true for an expired agent_id, got: #{inspect(context.response)}"

        assert context.response_text =~ context.agent_id,
               "expected the error to name the agent_id, got: #{context.response_text}"

        {:ok, context}
      end

      and_ "no Task in list_tasks carries the expired agent_id", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ListTasks.execute(%{session_id: context.session_id}, frame)

        text = TaskResponseHelpers.response_text(response)

        refute text =~ "agent=#{context.agent_id}",
               "expected no task to carry the TTL-expired agent_id, got:\n#{text}"

        {:ok, context}
      end
    end
  end
end
