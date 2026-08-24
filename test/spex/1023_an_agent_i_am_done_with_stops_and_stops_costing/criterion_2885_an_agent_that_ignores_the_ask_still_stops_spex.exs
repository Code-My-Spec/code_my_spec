defmodule CodeMySpecSpex.Story1023.Criterion2885Spex do
  @moduledoc """
  Story 1023 — An agent I am done with stops, and stops costing.
  Criterion 2885 — An agent that ignores the ask still stops.

  Rule: A stop asks the agent to finish what it is doing before it insists.

  The grace period is what lets an agent finish the commit it was making. It is
  bounded because the alternative is a stop the operator asked for that waits
  while the meter runs — and an agent mid-tool-call with a broken signal handler
  will wait forever.

  Uses an agent that traps the polite signal and keeps going. That is not a
  contrived case: a shell wrapper with `trap '' TERM`, an agent whose handler
  deadlocks on the work it is trying to finish, or one blocked in a syscall all
  produce it.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Agents.Tools.StopAgent
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A stop the operator asked for happens" do
    scenario "An agent that ignores the ask still stops" do
      given_ "an agent that answers neither the wind-down ask nor the signal that follows it",
             context do
        agent = Fixtures.running_agent(context.scope)
        start_agent(agent.id, working_copy: agent.working_copy)

        assert running?(agent.id),
               "the premise is a live agent that will refuse to go quietly"

        {:ok, context |> Map.put(:agent, agent)}
      end

      when_ "I stop it", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, reply, _frame} = StopAgent.execute(%{"agent_id" => context.agent.id}, frame)
        {:ok, Map.put(context, :reply, reply)}
      end

      then_ "it is ended anyway, within a bounded time", context do
        refute running?(context.agent.id),
               "an agent that ignored the polite signal is still running. A stop " <>
                 "that waits on an agent which was never going to answer is a stop " <>
                 "the meter outlives."

        {:ok, context}
      end

      then_ "and the stop does not wait on it indefinitely while the meter runs", context do
        refute context.reply.isError,
               "the stop reported an error rather than insisting"

        {:ok, context}
      end
    end
  end
end
