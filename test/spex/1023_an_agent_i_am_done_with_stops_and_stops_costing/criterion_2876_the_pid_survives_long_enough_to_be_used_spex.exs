defmodule CodeMySpecSpex.Story1023.Criterion2876Spex do
  @moduledoc """
  Story 1023 — An agent I am done with stops, and stops consuming.
  Criterion 2876 — The pid survives long enough to be used.

  Rule: The handle that can end a process is kept until the process is gone.

  `stop_agent/2` used to write `status: :stopped, os_pid: nil` in one update.
  Clearing the group id was the part with no way back: if the process survived,
  the only thing that could ever have reached it had just been thrown away, and
  the row said stopped so nobody was looking.

  ## The handle changed; the failure did not

  There is no group id now — an agent is a supervised process and its id is the
  handle. That does not make this criterion moot, it moves it. The irrecoverable
  step was never "the number was deleted", it was **the record stopped pointing
  at something that was still running**, so nothing tried again.

  A stop that could not reach the machine must leave the agent exactly as it
  found it: still running, still reachable, still asked-about. The next attempt
  then has something to act on, which is the whole difference between a failed
  stop and a permanent one.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Agents.Tools.StopAgent
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The handle outlives a stop that did not work" do
    scenario "The pid survives long enough to be used" do
      given_ "a running agent the server can name", context do
        agent = Fixtures.running_agent(context.scope)
        start_agent(agent.id, working_copy: agent.working_copy)

        assert running?(agent.id),
               "the premise is an agent that is really running; without one this " <>
                 "criterion asserts nothing about reaching it again"

        {:ok, Map.put(context, :agent, agent)}
      end

      when_ "a stop is asked for and the machine cannot be reached", context do
        machine_out_of_reach()

        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, reply, _frame} = StopAgent.execute(%{"agent_id" => context.agent.id}, frame)

        {:ok, Map.put(context, :reply, reply)}
      end

      then_ "the agent is still recorded as running", context do
        {:ok, after_stop} = Fixtures.fetch_agent(context.scope, context.agent.id)

        refute after_stop.status == :stopped,
               "the row says stopped over an agent that is still running. Nothing " <>
                 "is looking for it any more, so nothing will try again — that is " <>
                 "not a failed stop, it is a permanent one."

        assert after_stop.id == context.agent.id,
               "the id is the handle now; losing it would be losing the process"

        {:ok, context}
      end

      then_ "and the agent really is still running, so there is something to reach",
            context do
        assert running?(context.agent.id),
               "the premise of keeping the handle is that the thing it names is " <>
                 "still there. If the agent had actually stopped, keeping the row " <>
                 "would be the bug instead."

        {:ok, context}
      end
    end
  end
end
