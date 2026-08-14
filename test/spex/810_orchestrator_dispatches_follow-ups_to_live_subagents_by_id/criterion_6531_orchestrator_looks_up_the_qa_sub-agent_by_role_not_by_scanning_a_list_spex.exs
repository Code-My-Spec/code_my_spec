defmodule CodeMySpecSpex.Story810.Criterion6531Spex do
  @moduledoc """
  Story 810 — Orchestrator dispatches follow-ups to live subagents by id
  Criterion 6531 — Orchestrator looks up the QA sub-agent by role, not
  by scanning a list.

  Rule (f5b5f5d9): the session-level sub-agent registry is a map keyed
  by `:role` (`:qa`, `:coding`, `:spec_writer`, etc.) — at most one
  entry per role. Lookup is O(1) by role; the registry shape enforces
  the 1-per-role invariant.

  Surface: `list_session_subagents` MCP tool. The response must
  identify each sub-agent by its role (so the orchestrator can
  pick `registry[:qa]` directly), not just by opaque agent_id. With
  two sub-agents registered under distinct roles, the response must
  surface BOTH roles, distinctly addressable.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.ListSessionSubagents
  alias CodeMySpecSpex.TaskResponseHelpers

  @qa_agent_id "a-qa-role-1"
  @coding_agent_id "a-coding-role-1"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Registry is role-keyed: lookup by role, never by list-scan" do
    scenario "Two sub-agents under different roles — both surface with role identity" do
      given_ "the session has both a QA sub-agent and a Code Writer sub-agent registered",
             context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        post(
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
          |> Plug.Conn.put_req_header("content-type", "application/json"),
          "/api/hooks/session-start",
          %{"session_id" => session_id}
        )
        |> Phoenix.ConnTest.json_response(200)

        for {agent_id, role} <- [
              {@qa_agent_id, "qa"},
              {@coding_agent_id, "code-writer"}
            ] do
          post(
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
            |> Plug.Conn.put_req_header("content-type", "application/json"),
            "/api/hooks/subagent-start",
            %{
              "session_id" => session_id,
              "agent_id" => agent_id,
              "agent_name" => role
            }
          )
          |> Phoenix.ConnTest.json_response(200)
        end

        {:ok, Map.put(context, :session_id, session_id)}
      end

      when_ "the orchestrator queries list_session_subagents", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ListSessionSubagents.execute(%{session_id: context.session_id}, frame)

        {:ok, Map.put(context, :prompt, TaskResponseHelpers.response_text(response))}
      end

      then_ "each sub-agent is identified by its role and agent_id", context do
        prompt = context.prompt

        assert prompt =~ @qa_agent_id,
               "expected the QA agent_id `#{@qa_agent_id}` in the response, got:\n#{prompt}"

        assert prompt =~ @coding_agent_id,
               "expected the Code Writer agent_id `#{@coding_agent_id}` in the response, got:\n#{prompt}"

        assert prompt =~ ~r/\bqa\b/i,
               "expected the QA role identifier in the response, got:\n#{prompt}"

        assert prompt =~ ~r/code[\-\s_]?writer/i,
               "expected the Code Writer role identifier in the response, got:\n#{prompt}"

        {:ok, context}
      end
    end
  end
end
