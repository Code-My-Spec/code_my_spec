defmodule CodeMySpecSpex.Story704.Criterion6086Spex do
  @moduledoc """
  Story 704 — Agent administers their session
  Criterion 6086 — Main agent registers a freshly-spawned sub-agent.

  Covers Rule 1 (lifecycle hooks): firing `POST /api/hooks/subagent-start`
  with a fresh agent_id + agent_name persists a registration on the
  session. `Task.agent_id` is the assignment source of truth — and no
  task carries this sub-agent's agent_id yet (the sub-agent is idle).

  ## Surface

  This spec drives the real harness endpoint
  (`POST /api/hooks/subagent-start`) — Claude Code's `SubagentStart`
  hook routes to this URL via `hooks.json`. We observe the result
  through the LiveView session detail page, since that's what the
  engineer would see. (The MCP-tool surface is covered by 6093.)
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.HarnessHooks
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Main agent registers a freshly-spawned sub-agent", criterion: 431 do
    scenario "POST /subagent-start with a fresh agent_id appears in session state as idle" do
      given_ "a live harness serves the checkout", context do
        {:ok, HarnessHooks.ensure_live_harness(context)}
      end

      given_ "a live session exists with no registered sub-agents", context do
        session_id = "spex-6086-#{System.unique_integer([:positive])}"

        HarnessHooks.post_hook(context, "session-start", %{"session_id" => session_id})

        {:ok, Map.put(context, :session_id, session_id)}
      end

      when_ "the main agent fires subagent-start with a fresh agent_id and agent_name",
            context do
        agent_id = "test-writer-#{System.unique_integer([:positive])}"

        response =
          HarnessHooks.post_hook(context, "subagent-start", %{
            "session_id" => context.session_id,
            "agent_id" => agent_id,
            "agent_name" => "@test-writer"
          })

        {:ok, Map.merge(context, %{agent_id: agent_id, register_response: response})}
      end

      then_ "the hook responds with the registration echoed back", context do
        assert context.register_response["agent_id"] == context.agent_id,
               "expected the register response to echo the agent_id, got: #{inspect(context.register_response)}"

        assert context.register_response["agent_name"] == "@test-writer",
               "expected the register response to echo the agent_name, got: #{inspect(context.register_response)}"

        {:ok, context}
      end

      and_ "list_session_subagents shows the new registration as idle", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "list_session_subagents",
            %{session_id: context.session_id},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        text = TaskResponseHelpers.response_text(response)

        assert text =~ context.agent_id,
               "expected the new sub-agent in list_session_subagents, got:\n#{text}"

        # The row for this agent should be tagged idle (no task assignment).
        row =
          text
          |> String.split("\n")
          |> Enum.find(&String.contains?(&1, context.agent_id))

        assert row =~ "idle",
               "expected the new sub-agent to be tagged idle (no assignment), got row:\n#{row}"

        {:ok, context}
      end
    end
  end
end
