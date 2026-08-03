defmodule CodeMySpecSpex.Story704.Criterion6094Spex do
  @moduledoc """
  Story 704 — Agent administers their session
  Criterion 6094 — TTL-expired registration is absent from both surfaces.

  Covers Rule 3's parity: the engineer's session detail LiveView and
  the `list_session_subagents` MCP tool must agree on what's visible.
  A registration whose `last_heartbeat_at` is older than TTL appears
  on NEITHER surface.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.ListSessionSubagents
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "TTL-expired registration is absent from both surfaces" do
    scenario "stale registration is filtered out of LiveView AND MCP tool response" do
      given_ "a session with one registration whose heartbeat is past the TTL",
             context do
        session_id = "spex-6094-#{System.unique_integer([:positive])}"
        agent_id = "stale-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post(~p"/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        {:ok, _session} =
          Fixtures.register_subagent_with_heartbeat(context.scope, session_id, %{
            agent_id: agent_id,
            agent_name: "@stale",
            last_heartbeat_at:
              DateTime.utc_now()
              |> DateTime.add(-30 * 60, :second)
              |> DateTime.truncate(:second)
          })

        session = Fixtures.get_session_by_external_id(context.scope, session_id)

        {:ok,
         Map.merge(context, %{
           session_id: session_id,
           session_db_id: session.id,
           agent_id: agent_id
         })}
      end

      when_ "the engineer opens the session page AND the agent calls list_session_subagents",
            context do
        {:ok, view, _html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/sessions/#{context.session_db_id}"
          )

        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, mcp_response, _frame} =
          ListSessionSubagents.execute(%{session_id: context.session_id}, frame)

        {:ok,
         Map.merge(context, %{
           view: view,
           mcp_text: TaskResponseHelpers.response_text(mcp_response)
         })}
      end

      then_ "neither the LiveView nor the MCP response includes the stale registration",
            context do
        refute has_element?(
                 context.view,
                 "[data-test='subagent-row'][data-agent-id='#{context.agent_id}']"
               ),
               "expected LiveView to omit stale registration #{context.agent_id}"

        refute context.mcp_text =~ context.agent_id,
               "expected MCP response to omit stale registration #{context.agent_id}, got:\n#{context.mcp_text}"

        {:ok, context}
      end

      and_ "the LiveView still renders its Registered Sub-agents heading (anchor)",
           context do
        assert has_element?(context.view, "[data-test='registered-subagents-heading']"),
               "expected the section heading to render even with all entries pruned"

        {:ok, context}
      end
    end
  end
end
