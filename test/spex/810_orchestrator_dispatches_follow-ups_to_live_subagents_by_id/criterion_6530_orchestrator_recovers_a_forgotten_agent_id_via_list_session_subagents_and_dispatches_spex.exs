defmodule CodeMySpecSpex.Story810.Criterion6530Spex do
  @moduledoc """
  Story 810 — Orchestrator dispatches follow-ups to live subagents by id
  Criterion 6530 — Orchestrator recovers a forgotten agent_id via
  `list_session_subagents` and dispatches.

  Rule (854b1b22): when the orchestrator loses track of an agent_id
  locally (compaction, long session), `list_session_subagents` is the
  recovery surface — it returns every live sub-agent on the session
  with its agent_id + the task it's assigned to.

  Surface: `list_session_subagents` MCP tool. With a registered
  sub-agent on the session, the response must surface the agent_id
  and identify the sub-agent role so the orchestrator can pick
  the right SendMessage target without re-spawning.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.ListSessionSubagents
  alias CodeMySpecSpex.TaskResponseHelpers

  @qa_agent_id "a-qa-recover-1"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "list_session_subagents is the recovery surface for forgotten agent_ids" do
    scenario "register a QA sub-agent; list returns its agent_id + role" do
      given_ "the session has a live QA sub-agent registered",
             context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        post(
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
          |> Plug.Conn.put_req_header("content-type", "application/json"),
          "/api/hooks/session-start",
          %{"session_id" => session_id}
        )
        |> Phoenix.ConnTest.json_response(200)

        post(
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
          |> Plug.Conn.put_req_header("content-type", "application/json"),
          "/api/hooks/subagent-start",
          %{
            "session_id" => session_id,
            "agent_id" => @qa_agent_id,
            "agent_name" => "qa"
          }
        )
        |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :session_id, session_id)}
      end

      when_ "the orchestrator calls list_session_subagents", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ListSessionSubagents.execute(%{session_id: context.session_id}, frame)

        {:ok, Map.put(context, :prompt, TaskResponseHelpers.response_text(response))}
      end

      then_ "the response surfaces the live agent_id and identifies the role", context do
        prompt = context.prompt

        assert prompt =~ @qa_agent_id,
               "expected the response to include the live agent_id `#{@qa_agent_id}`, got:\n#{prompt}"

        assert prompt =~ ~r/\bqa\b/i,
               "expected the response to identify the sub-agent role (qa) so the orchestrator can pick the right one, got:\n#{prompt}"

        {:ok, context}
      end
    end
  end
end
