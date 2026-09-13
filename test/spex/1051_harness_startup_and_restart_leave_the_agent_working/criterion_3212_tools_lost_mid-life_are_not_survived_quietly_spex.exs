defmodule CodeMySpecSpex.Story1051.Criterion3212Spex do
  @moduledoc """
  Story 1051 — Harness startup and restart leave the agent working.
  Criterion 3212 — Tools lost mid-life are not survived quietly.

  Rule: An agent whose tools do not resolve fails loudly instead of running.

  The loss that actually happened. 3211 and 3462 are about the start, where
  there is at least a caller waiting for an answer; this is about an agent that
  started correctly and lost its tool surface underneath it, where there is
  nobody.

  Both Thens are about *who reads the failure*. A tool error returned as a tool
  result goes to the model, and the model is the one reader who cannot act on
  it: it will apologise, try a different tool, apologise again, and keep
  spending turns — which is the four hours, and the reason "agent restarts made
  it worse" rather than better.

  ## How the premise is made

  By taking away the scope the agent's tool calls are made with, which is what
  the local MCP transport resolves a call against. That is a stand-in for the
  stale client in the incident, and it is the same observable: the agent is up,
  its tool list is unchanged, and every call fails.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers, only: [running?: 1]
  import CodeMySpecSpex.HarnessLifecycleHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An agent whose tools do not resolve fails loudly instead of running" do
    scenario "Tools lost mid-life are not survived quietly" do
      given_ "a running agent whose tools stop resolving", context do
        context = given_a_staffed_checkout(context, "spex_3212")
        agent_id = start_agent(context)

        Fixtures.authored_story(context.scope, "a story the agent's tools can find")

        assert {:ok, _} = tool_call(agent_id),
               "the premise is an agent whose tools worked and then stopped; this " <>
                 "one's never worked, so nothing is lost mid-life"

        # The surface goes away underneath it. The agent is untouched — same
        # process, same tool list, same everything it can see about itself.
        Application.delete_env(:code_my_spec, :harness_mcp_scope)

        assert carried_tools(agent_id) != [],
               "the agent has to still believe it has tools, or this is 3462 again"

        {:ok, Map.put(context, :agent_id, agent_id)}
      end

      when_ "it attempts a tool call", context do
        {:ok, Map.put(context, :outcome, attempt_tool_call(context.agent_id))}
      end

      then_ "the failure is raised rather than returned as a tool result the model reads",
            context do
        assert match?({:raised, _}, context.outcome),
               """
               The lost tool surface came back to the agent as a value.

               Whatever is in it, the model is the one reader who cannot act on
               it. It will read a failed call as a tool that did not work,
               apologise, try another, and keep going — spending turns on
               somebody's subscription against machinery that is broken
               underneath it and that no amount of the agent's own effort can
               repair.

               Raising puts the failure where the supervisor and the log are,
               which is where somebody who can fix it is looking.

               got: #{inspect(context.outcome)}
               """

        {:ok, context}
      end

      then_ "and the agent does not continue taking turns without tools", context do
        refute running?(context.agent_id),
               """
               The agent is still running with no working tools.

               An agent in this state is worse than a stopped one: it answers,
               it looks healthy on every page, and everything it is asked to do
               quietly fails. The story's note is what that costs — four hours,
               and restarting the agent made it worse because the fault was
               never the agent's.
               """

        {:ok, context}
      end
    end
  end
end
