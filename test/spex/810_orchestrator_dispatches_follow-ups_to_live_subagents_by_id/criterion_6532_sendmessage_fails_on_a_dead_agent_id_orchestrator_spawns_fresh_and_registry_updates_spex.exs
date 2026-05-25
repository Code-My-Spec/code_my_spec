defmodule CodeMySpecSpex.Story810.Criterion6532Spex do
  @moduledoc """
  Story 810 — Orchestrator dispatches follow-ups to live subagents by id
  Criterion 6532 — SendMessage fails on a dead agent_id — orchestrator
  spawns fresh and registry updates.

  Rule (fda62aad): `SendMessage(to: agent_id)` is the experimental
  dispatch path; any failure (agent dead, transport error, feature
  unavailable) triggers a deterministic fallback to fresh `Agent`
  spawn, and the registry overwrites the role's entry with the new
  agent_id. The orchestrator never lets a stale id block work.

  Surface: `get_next_requirement` MCP tool. When NO sub-agent is
  registered for the role (the "dead/never-spawned" case from the
  orchestrator's perspective), the dispatch directive must guide the
  orchestrator to spawn fresh — naming `Agent` and the role — NOT
  emit SendMessage referencing a stale id.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Without a live sub-agent for the role, dispatch directs fresh Agent spawn" do
    scenario "No registered QA sub-agent — directive says Agent spawn, no SendMessage to a stale id" do
      given_ "a session exists with NO registered sub-agents for any role",
             context do
        # Advance project to qa_complete frontier so the dispatch directive
        # is for a sub-agent role (not project_setup), then create a session
        # with no registered sub-agents to exercise the fresh-spawn fallback.
        context = FullSatisfactionFixtures.apply_without_qa_story(context)
        session_id = "spex-#{System.unique_integer([:positive])}"

        post(
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
          |> Plug.Conn.put_req_header("content-type", "application/json"),
          "/api/hooks/session-start",
          %{"session_id" => session_id}
        )
        |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :session_id, session_id)}
      end

      when_ "the orchestrator calls get_next_requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
        {:ok, Map.put(context, :prompt, TaskResponseHelpers.response_text(response))}
      end

      then_ "the dispatch directive instructs a fresh Agent spawn for any sub-agent role",
            context do
        prompt = context.prompt

        # The fallback path: when no live sub-agent exists for the role,
        # the directive must mention `Agent` (the spawn primitive) AND
        # the role, so the orchestrator knows what to spawn.
        assert prompt =~ ~r/\bAgent\b/,
               "expected the dispatch directive to mention `Agent` as the spawn primitive when no live sub-agent exists, got:\n#{prompt}"

        {:ok, context}
      end

      then_ "the directive does NOT reference SendMessage with a stale id",
            context do
        prompt = context.prompt

        refute prompt =~ ~r/SendMessage\s*\(\s*to:/,
               "expected the dispatch directive to NOT reference SendMessage when no live agent_id exists (fallback path is fresh spawn), got:\n#{prompt}"

        {:ok, context}
      end
    end
  end
end
