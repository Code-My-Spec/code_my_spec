defmodule CodeMySpecSpex.Story704.Criterion6091Spex do
  @moduledoc """
  Story 704 — Agent administers their session
  Criterion 6091 — Long-running sub-agent re-registers to keep its slot.

  Covers Rule 2's escape-hatch: a sub-agent whose work legitimately
  takes longer than the TTL refreshes its registration by firing
  `SubagentStart` again with the same `agent_id`. The
  `last_heartbeat_at` advances and the registration survives the
  next session read past the original TTL boundary.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.ListSessionSubagents
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Long-running sub-agent re-registers to keep its slot" do
    scenario "second SubagentStart for same agent_id refreshes heartbeat" do
      given_ "a session with a sub-agent whose original heartbeat is past the TTL",
             context do
        session_id = "spex-6091-#{System.unique_integer([:positive])}"
        agent_id = "long-running-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post(~p"/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        # Seed with an old heartbeat — would normally be pruned
        {:ok, _session} =
          Fixtures.register_subagent_with_heartbeat(context.scope, session_id, %{
            agent_id: agent_id,
            agent_name: "@long-running",
            last_heartbeat_at:
              DateTime.utc_now()
              |> DateTime.add(-30 * 60, :second)
              |> DateTime.truncate(:second)
          })

        {:ok, Map.merge(context, %{session_id: session_id, agent_id: agent_id})}
      end

      when_ "the sub-agent fires SubagentStart again with the same agent_id", context do
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post(~p"/api/hooks/subagent-start", %{
          "session_id" => context.session_id,
          "agent_id" => context.agent_id,
          "agent_name" => "@long-running"
        })
        |> Phoenix.ConnTest.json_response(200)

        {:ok, context}
      end

      then_ "the registration survives the next read (heartbeat advanced)", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ListSessionSubagents.execute(%{session_id: context.session_id}, frame)

        text = TaskResponseHelpers.response_text(response)

        assert text =~ context.agent_id,
               "expected re-registered sub-agent to survive the next read, got:\n#{text}"

        {:ok, context}
      end
    end
  end
end
