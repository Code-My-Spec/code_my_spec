defmodule CodeMySpecSpex.Story1051.Criterion3204Spex do
  @moduledoc """
  Story 1051 — Harness startup and restart leave the agent working.
  Criterion 3204 — Tools come back on their own after a harness restart.

  Rule: An agent's tools work again after its harness restarts, with nobody
  intervening.

  The story's note is the incident this inverts: a stale MCP client left an
  agent toolless for four hours, agent restarts made it worse, and only a
  harness restart cleared it. If the harness restart is the thing that fixes
  it, then after one the agent has to be able to call a tool again.

  "With nobody intervening" is the half that fails separately and silently. An
  agent that works once somebody restarts *it* is a system whose recovery is a
  person noticing — which is the four hours, not a fix for them.

  Asserted on a tool **call**, not a tool list. The whole incident was an agent
  whose tools were listed and did not work; a list proves the manifest and says
  nothing about the client behind it.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers, only: [restart_harness: 1, running?: 1]
  import CodeMySpecSpex.HarnessLifecycleHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An agent's tools work again after its harness restarts, with nobody intervening" do
    scenario "Tools come back on their own after a harness restart" do
      given_ "a running agent whose tools work", context do
        context = given_a_staffed_checkout(context, "spex_3204")
        agent_id = start_agent(context)

        # A story for the call to find, so "it answered" is distinguishable
        # from "it answered nothing at all" — an empty list reads as success
        # against a tool that never ran.
        Fixtures.authored_story(context.scope, "a story the agent's tools can find")

        assert {:ok, _} = tool_call(agent_id),
               "the premise is an agent whose tools work, and this one's do not " <>
                 "before anything has restarted"

        {:ok, Map.put(context, :agent_id, agent_id)}
      end

      when_ "its harness is restarted", context do
        restart_harness(context.harness_socket)

        {:ok, context}
      end

      then_ "the agent's next tool call succeeds", context do
        assert {:ok, body} = tool_call(context.agent_id),
               """
               The agent cannot call a tool after its harness came back.

               This is the four hours in the story's note: the agent is up, it
               is answering, and every tool call it makes fails. Nothing it does
               from here can repair that, because the thing that was stale is
               the client underneath it.
               """

        assert body =~ "a story the agent's tools can find",
               """
               The call went through and came back with something other than
               this project's stories, so the tools resolved to a surface that
               is not the agent's own. Got: #{inspect(body)}
               """

        {:ok, context}
      end

      then_ "and nobody restarted the agent to make that true", context do
        assert running?(context.agent_id),
               """
               The agent is not running, so whatever answered above was not it
               coming back on its own — and a recovery that needs somebody to
               restart the agent is a recovery that waits on somebody noticing.
               """

        {:ok, context}
      end
    end
  end
end
