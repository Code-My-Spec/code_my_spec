defmodule CodeMySpecSpex.Story704.Criterion6087Spex do
  @moduledoc """
  Story 704 — Agent administers their session
  Criterion 6087 — Registered sub-agent claims a task via start_task.

  Covers Rule 1's assignment half: `Task.agent_id` is the source of
  truth for "this task belongs to that sub-agent." A registered
  sub-agent claims an open requirement by calling `start_task` with
  their `agent_id`; the resulting Task carries that id.

  Combines two surfaces:
  - `POST /api/hooks/subagent-start` (registers the sub-agent on session)
  - `start_task` MCP tool with `agent_id` parameter (claims a task)
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.ListTasks
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Registered sub-agent claims a task via start_task with their agent_id" do
    scenario "the resulting Task carries the sub-agent's agent_id" do
      given_ :synced_context_component

      given_ "a live session exists with one registered sub-agent", context do
        session_id = "spex-6087-#{System.unique_integer([:positive])}"
        agent_id = "code-writer-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post(~p"/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post(~p"/api/hooks/subagent-start", %{
          "session_id" => session_id,
          "agent_id" => agent_id,
          "agent_name" => "@code-writer"
        })
        |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.merge(context, %{session_id: session_id, agent_id: agent_id})}
      end

      when_ "the sub-agent calls start_task with their agent_id", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "spec_file",
              entity_type: "component",
              entity_id: to_string(context.component.id),
              session_id: context.session_id,
              agent_id: context.agent_id
            },
            frame
          )

        refute response.isError,
               "expected start_task to succeed, got: #{inspect(response)}"

        {:ok, context}
      end

      then_ "list_tasks shows a Task carrying that agent_id for spec_file",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ListTasks.execute(%{session_id: context.session_id}, frame)

        text = TaskResponseHelpers.response_text(response)

        # Each row reports `agent=<agent_id>` and the requirement_name.
        # Search for a row that has BOTH the spec_file requirement AND
        # the sub-agent's agent_id.
        line =
          text
          |> String.split("\n")
          |> Enum.find(&(&1 =~ "spec_file" and &1 =~ "agent=#{context.agent_id}"))

        assert line,
               "expected a list_tasks row pairing spec_file with agent_id=#{context.agent_id}, got:\n#{text}"

        {:ok, context}
      end
    end
  end
end
