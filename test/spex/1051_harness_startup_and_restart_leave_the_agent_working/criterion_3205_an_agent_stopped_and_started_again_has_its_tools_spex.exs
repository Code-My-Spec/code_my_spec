defmodule CodeMySpecSpex.Story1051.Criterion3205Spex do
  @moduledoc """
  Story 1051 — Harness startup and restart leave the agent working.
  Criterion 3205 — An agent stopped and started again has its tools.

  Rule: Stopping an agent leaves nothing behind that breaks the next one.

  The second half of the criterion is the one with teeth. "Its tools resolve"
  is satisfiable by an agent that came up holding the *previous* run's MCP
  client, right up to the moment that client goes stale — and then it is the
  four hours in the story's note, with the agent reporting a full tool list and
  every call failing.

  So the leftover is asserted directly: the client the second agent holds must
  not be the one the first agent held. `CmsHarness.Agents.Engine.terminate/2`
  disconnects on the way down for exactly this reason, and before it did, an
  agent's successor inherited a session nobody could use.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessLifecycleHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Stopping an agent leaves nothing behind that breaks the next one" do
    scenario "An agent stopped and started again has its tools" do
      given_ "a running agent with working tools", context do
        context = given_a_staffed_checkout(context, "spex_3205")
        agent_id = start_agent(context)

        Fixtures.authored_story(context.scope, "a story the agent's tools can find")

        assert {:ok, _} = tool_call(agent_id),
               "the premise is an agent whose tools work, and this one's do not"

        assert Fixtures.agent_tool_context(agent_id).mcp_client,
               "the premise is an agent holding a client it could leave behind"

        {:ok, Map.put(context, :first, agent_id)}
      end

      when_ "the agent is stopped and started again", context do
        stop_agent(context, context.first)

        {:ok, Map.put(context, :second, start_agent(context))}
      end

      then_ "its tools resolve", context do
        assert {:ok, body} = tool_call(context.second),
               """
               The agent that replaced a stopped one cannot call a tool.

               Stopping is the ordinary thing an operator does, and an agent
               that comes back toolless from it turns every stop into an
               outage — which is how restarting the agent made the original
               incident worse rather than better.
               """

        assert body =~ "a story the agent's tools can find",
               "the call resolved to something that is not this project's tools: " <>
                 inspect(body)

        {:ok, context}
      end

      then_ "and it holds no client left over from the previous run", context do
        refute Fixtures.agent_tool_context(context.first).mcp_client,
               """
               The stopped agent still has a client.

               That is the leftover in the rule's own words, and it is what the
               successor collides with: the client registers under a name
               derived from the agent, so one that outlives its agent is a name
               the next start cannot have. `Engine.terminate/2` disconnects on
               the way down for exactly this reason, and a `terminate/2` that
               stops running is invisible until the next start fails.

               Asked of the stopped agent rather than by comparing the two
               clients, because comparing them cannot fail here: the in-process
               transport hands every agent the same constant, so an equality
               check would be asserting about the double.

               held: #{inspect(Fixtures.agent_tool_context(context.first).mcp_client)}
               """

        {:ok, context}
      end
    end
  end
end
