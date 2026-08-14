defmodule CodeMySpecSpex.Story810.Criterion6529Spex do
  @moduledoc """
  Story 810 — Orchestrator dispatches follow-ups to live subagents by id
  Criterion 6529 — Follow-up probe dispatched via SendMessage continues
  the original QA sub-agent's conversation.

  Rule (854b1b22): after spawning a sub-agent, follow-ups MUST go via
  `SendMessage(to: agent_id)` — not a fresh `Agent` spawn — so the
  conversation, browser session, and accumulated state are preserved.

  Surface: `get_next_requirement` MCP tool. When a `qa_complete`
  requirement is pending AND the session already has a live QA
  sub-agent registered, the rendered dispatch directive must NAME
  SendMessage and include the live `agent_id` so the orchestrator
  knows to re-address the existing conversation instead of spawning
  fresh. (We don't drive Claude Code's Agent tool from spex — we
  test that the prompt the orchestrator receives says the right
  thing.)
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias CodeMySpecSpex.TaskResponseHelpers

  @qa_agent_id "a-qa-spex-1"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Dispatch directive names SendMessage when a live QA sub-agent is registered" do
    scenario "qa_complete requirement + registered QA sub-agent → directive says SendMessage(to: <agent_id>)" do
      given_ "a story exists with a passing-spec'd qa_complete requirement pending",
             context do
        # Advance the project to the qa_complete frontier: all prereqs satisfied
        # (project chain + story chain through bdd_specs_passing) but qa_complete
        # itself left open so it appears as the next actionable requirement.
        {:ok, FullSatisfactionFixtures.apply_without_qa_story(context)}
      end

      and_ "the session has a live QA sub-agent registered with a known agent_id",
           context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        # SessionStart — creates the session row.
        post(
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
          |> Plug.Conn.put_req_header("content-type", "application/json"),
          "/api/hooks/session-start",
          %{"session_id" => session_id}
        )
        |> Phoenix.ConnTest.json_response(200)

        # SubagentStart — registers the QA sub-agent under a known id.
        post(
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
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

      when_ "the orchestrator calls get_next_requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
        {:ok, Map.put(context, :prompt, TaskResponseHelpers.response_text(response))}
      end

      then_ "the rendered directive names SendMessage and the live agent_id",
            context do
        prompt = context.prompt

        assert prompt =~ "SendMessage",
               "expected the dispatch directive to name `SendMessage` so the orchestrator continues the existing conversation, got:\n#{prompt}"

        assert prompt =~ @qa_agent_id,
               "expected the dispatch directive to include the live agent_id `#{@qa_agent_id}` so the orchestrator knows which conversation to address, got:\n#{prompt}"

        {:ok, context}
      end

      then_ "the directive does NOT instruct a fresh Agent spawn when a live agent exists",
            context do
        prompt = context.prompt

        refute prompt =~ ~r/Spawn\s+a\s+@qa\s+sub-agent/i,
               "expected the dispatch directive to PREFER SendMessage over fresh spawn when the QA agent is already live, got:\n#{prompt}"

        {:ok, context}
      end
    end
  end
end
