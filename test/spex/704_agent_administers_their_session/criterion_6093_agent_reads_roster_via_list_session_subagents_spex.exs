defmodule CodeMySpecSpex.Story704.Criterion6093Spex do
  @moduledoc """
  Story 704 — Agent administers their session
  Criterion 6093 — Agent reads the same roster through `list_session_subagents`.

  Covers Rule 3's MCP-side: the agent has a tool to inspect the
  session's registered sub-agents with the same identity + assignment
  classification the engineer's session detail page renders.

  Sets up one idle sub-agent and one sub-agent assigned to an open
  task (via start_task with their agent_id), then drives the MCP tool
  and asserts both registrations + their classifications appear.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.ListSessionSubagents
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Agent reads roster of registered sub-agents through MCP tool" do
    scenario "list_session_subagents returns both idle and assigned sub-agents" do
      given_ :synced_context_component

      given_ "a session with two registered sub-agents (one idle, one assigned)",
             context do
        session_id = "spex-6093-#{System.unique_integer([:positive])}"
        idle_agent = "idle-#{System.unique_integer([:positive])}"
        assigned_agent = "assigned-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post(~p"/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        for {agent_id, agent_name} <- [
              {idle_agent, "@idle-agent"},
              {assigned_agent, "@assigned-agent"}
            ] do
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/subagent-start", %{
            "session_id" => session_id,
            "agent_id" => agent_id,
            "agent_name" => agent_name
          })
          |> Phoenix.ConnTest.json_response(200)
        end

        # assigned_agent claims the spec_file task
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "spec_file",
              entity_type: "component",
              entity_id: to_string(context.component.id),
              session_id: session_id,
              agent_id: assigned_agent
            },
            frame
          )

        {:ok,
         Map.merge(context, %{
           session_id: session_id,
           idle_agent: idle_agent,
           assigned_agent: assigned_agent
         })}
      end

      when_ "the agent calls list_session_subagents", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ListSessionSubagents.execute(%{session_id: context.session_id}, frame)

        {:ok, Map.put(context, :response_text, TaskResponseHelpers.response_text(response))}
      end

      then_ "the response lists both sub-agents with their identities", context do
        text = context.response_text

        assert text =~ context.idle_agent,
               "expected idle sub-agent #{context.idle_agent} in response, got:\n#{text}"

        assert text =~ context.assigned_agent,
               "expected assigned sub-agent #{context.assigned_agent} in response, got:\n#{text}"

        {:ok, context}
      end

      and_ "the idle agent shows as idle and the assigned agent shows their task",
           context do
        text = context.response_text

        # Each line carries the agent_id and its classification. Match
        # the idle sub-agent's line and verify it's tagged idle.
        idle_line =
          text
          |> String.split("\n")
          |> Enum.find(&String.contains?(&1, context.idle_agent))

        assert idle_line =~ "idle",
               "expected idle classification for #{context.idle_agent}, got line:\n#{idle_line}"

        assigned_line =
          text
          |> String.split("\n")
          |> Enum.find(&String.contains?(&1, context.assigned_agent))

        assert assigned_line =~ "assigned",
               "expected `assigned` classification for #{context.assigned_agent}, got line:\n#{assigned_line}"

        {:ok, context}
      end
    end
  end
end
