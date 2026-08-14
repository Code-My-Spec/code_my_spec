defmodule CodeMySpecSpex.Story538.Criterion6485Spex do
  @moduledoc """
  Story 538 — LLM Agent Autonomous Task Execution
  Criterion 6485 — Subagent-owned active task short-circuits the main
  agent's stop to allow without validation.

  Covers Rule R5(a): "A sub-agent alive + assigned + working: main
  agent's stop hook does not run (main is idle by design while sub-agent
  works)."

  The complement to criterion 5119 (R5(b)): there, the task has no
  agent_id and an idle sub-agent exists → stop hook blocks with an
  assign directive. Here, the task already carries the sub-agent's
  agent_id (the sub-agent owns it) → stop hook short-circuits with the
  empty allow signal, no validation runs.

  ## Surface

  Sub-agent registration goes through the production webhook
  `POST /api/hooks/subagent-start`. The task is created via the
  `start_task` MCP tool, then assigned to the sub-agent via the
  `assign_subagent` MCP tool. Stop hook fires at the real endpoint
  `POST /api/hooks/stop`.

  ## What this asserts

  When the session has an active task whose `agent_id` points to a
  registered, alive sub-agent, the stop hook's first cond branch
  (`has_active_subagent_task?`) returns true and the hook returns the
  empty allow signal `{}`. Crucially: NO validation pipeline runs, so
  the parent agent never gets "Brief not found" / spec-validation
  feedback for work the sub-agent is mid-flight on.
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

  spex "Subagent-owned active task short-circuits the main agent's stop" do
    scenario "stop hook allows without validation when a subagent owns the active task" do
      given_ :synced_context_component

      given_ "a session with one open task assigned to a registered sub-agent",
             context do
        session_id = "spex-6485-#{System.unique_integer([:positive])}"
        agent_id = "subagent-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post(~p"/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post(~p"/api/hooks/subagent-start", %{
          "session_id" => session_id,
          "agent_id" => agent_id,
          "agent_name" => "@subagent"
        })
        |> Phoenix.ConnTest.json_response(200)

        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _resp, _frame} =
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

        {:reply, _assign_resp, _frame} =
          AssignSubagent.execute(
            %{
              session_id: session_id,
              agent_id: agent_id,
              task_id: task_id
            },
            frame
          )

        {:ok,
         Map.merge(context, %{
           session_id: session_id,
           agent_id: agent_id,
           task_id: task_id
         })}
      end

      when_ "the main agent's stop hook fires", context do
        response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/stop", %{"session_id" => context.session_id})
          |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the response is the empty allow signal", context do
        assert context.response == %{},
               "expected the empty allow signal {}, got: #{inspect(context.response)}"

        {:ok, context}
      end

      and_ "no validation feedback (Brief / spec / pipeline) appears in the response",
           context do
        body = Jason.encode!(context.response)

        refute body =~ "Brief not found",
               "validation pipeline must not run when a sub-agent owns the task, got: #{body}"

        refute body =~ "spec",
               "spec-validation must not run when a sub-agent owns the task, got: #{body}"

        refute Map.has_key?(context.response, "decision"),
               "no block/allow decision should be embedded — short-circuit returns plain {}, got: #{inspect(context.response)}"

        {:ok, context}
      end
    end
  end
end
