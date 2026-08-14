defmodule CodeMySpecSpex.Story704.Criterion6088Spex do
  @moduledoc """
  Story 704 — Agent administers their session
  Criterion 6088 — Sub-agent stop hook unregisters the sub-agent.

  Covers Rule 1's unregister half. The existing SubagentStop controller
  was responsible for validation + task evaluation; story 704 adds the
  registry-cleanup step so the registration is gone after a clean
  shutdown.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.ListSessionSubagents
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Sub-agent stop hook unregisters the sub-agent" do
    scenario "POST /subagent-stop removes the registration from session state" do
      given_ "a live session with a registered sub-agent", context do
        session_id = "spex-6088-#{System.unique_integer([:positive])}"
        agent_id = "test-writer-#{System.unique_integer([:positive])}"

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
          "agent_name" => "@test-writer"
        })
        |> Phoenix.ConnTest.json_response(200)

        # Precondition (observed through the public MCP tool): the
        # sub-agent is currently registered.
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ListSessionSubagents.execute(%{session_id: session_id}, frame)

        text = TaskResponseHelpers.response_text(response)

        assert text =~ agent_id,
               "precondition: expected #{agent_id} in list_session_subagents before stop, got:\n#{text}"

        {:ok, Map.merge(context, %{session_id: session_id, agent_id: agent_id})}
      end

      when_ "the main agent fires POST /subagent-stop with that agent_id", context do
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post(~p"/api/hooks/subagent-stop", %{
          "session_id" => context.session_id,
          "agent_id" => context.agent_id
        })
        |> Phoenix.ConnTest.json_response(200)

        {:ok, context}
      end

      then_ "the registry entry is absent from list_session_subagents", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ListSessionSubagents.execute(%{session_id: context.session_id}, frame)

        text = TaskResponseHelpers.response_text(response)

        refute text =~ context.agent_id,
               "expected the sub-agent to be unregistered after subagent-stop, got:\n#{text}"

        {:ok, context}
      end
    end
  end
end
