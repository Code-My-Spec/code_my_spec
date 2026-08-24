defmodule CodeMySpecSpex.Story1023.Criterion2876Spex do
  @moduledoc """
  Story 1023 — An agent I am done with stops, and stops costing.
  Criterion 2876 — The pid survives long enough to be used.

  Rule: The handle that can end a process is kept until the process is gone.

  `stop_agent/2` used to write `status: :stopped, os_pid: nil` in one update.
  Clearing the group id is the part with no way back: if the process survived,
  the only thing that could ever have reached it has just been thrown away, and
  the row says the agent is stopped so nobody is looking.

  So the handle is cleared *after* something confirms the group is gone, and a
  stop that could not happen leaves it exactly where it was. The next attempt
  then has something to act on, which is the whole difference between a failure
  and a permanent one.
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
      given_ "a running agent whose os_pid is recorded", context do
        process = start_process()
        agent = Fixtures.running_agent(context.scope, process)

        assert agent.os_pid == process.os_pid
        assert is_binary(agent.os_boot_id)

        {:ok, context |> Map.put(:agent, agent) |> Map.put(:process, process)}
      end

      when_ "a stop is asked for and the process does not end", context do
        machine_out_of_reach()

        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, reply, _frame} = StopAgent.execute(%{"agent_id" => context.agent.id}, frame)

        {:ok, Map.put(context, :reply, reply)}
      end

      then_ "the os_pid is still recorded", context do
        {:ok, after_stop} = Fixtures.fetch_agent(context.scope, context.agent.id)

        assert after_stop.os_pid == context.process.os_pid,
               "the group id was cleared by a stop that ended nothing. The process " <>
                 "is still running and nothing can reach it any more — that is not " <>
                 "a failed stop, it is a permanent one."

        assert after_stop.os_boot_id == context.agent.os_boot_id,
               "the boot went with it, so even a recovered group id could not be " <>
                 "judged against a recycled number"

        {:ok, Map.put(context, :after_stop, after_stop)}
      end

      then_ "and a second attempt has something to act on", context do
        # The machine comes back. The same stop now works, because the handle
        # was still there to use.
        Application.put_env(
          :code_my_spec,
          :agent_transport,
          CodeMySpecTest.InProcessAgentTransport
        )

        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, retry, _frame} = StopAgent.execute(%{"agent_id" => context.agent.id}, frame)

        refute retry.isError

        assert in_group(context.process.os_pid) == [],
               "the retry had a handle and still did not end the process"

        {:ok, context}
      end
    end
  end
end
