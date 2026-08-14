defmodule CodeMySpecSpex.Story704.Criterion6089Spex do
  @moduledoc """
  Story 704 — Agent administers their session
  Criterion 6089 — Fresh registration survives within the TTL window.

  Covers Rule 2's happy path: a sub-agent whose `last_heartbeat_at`
  is within the configured TTL appears in the response when the
  session is read (either surface). We observe through the MCP tool
  (`list_session_subagents`) since that's the smallest surface that
  consumes `Session.active_subagents/2`.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.ListSessionSubagents
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Fresh registration survives within the TTL window" do
    scenario "sub-agent registered less than TTL ago appears in list_session_subagents" do
      given_ "a session with a freshly-registered sub-agent (heartbeat ~now)",
             context do
        session_id = "spex-6089-#{System.unique_integer([:positive])}"
        agent_id = "fresh-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post(~p"/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        # Heartbeat 1 minute ago (well within the 10-minute default TTL)
        {:ok, _session} =
          Fixtures.register_subagent_with_heartbeat(context.scope, session_id, %{
            agent_id: agent_id,
            agent_name: "@fresh",
            last_heartbeat_at:
              DateTime.utc_now()
              |> DateTime.add(-60, :second)
              |> DateTime.truncate(:second)
          })

        {:ok, Map.merge(context, %{session_id: session_id, agent_id: agent_id})}
      end

      when_ "the agent calls list_session_subagents", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ListSessionSubagents.execute(%{session_id: context.session_id}, frame)

        {:ok, Map.put(context, :response_text, TaskResponseHelpers.response_text(response))}
      end

      then_ "the response includes the fresh sub-agent", context do
        assert context.response_text =~ context.agent_id,
               "expected fresh sub-agent in response, got:\n#{context.response_text}"

        {:ok, context}
      end
    end
  end
end
