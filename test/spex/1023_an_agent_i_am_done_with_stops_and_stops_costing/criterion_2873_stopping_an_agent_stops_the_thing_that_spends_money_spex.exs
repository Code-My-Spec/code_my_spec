defmodule CodeMySpecSpex.Story1023.Criterion2873Spex do
  @moduledoc """
  Story 1023 — An agent I am done with stops, and stops costing.
  Criterion 2873 — Stopping an agent stops the thing that spends money.

  Rule: Stopping an agent ends its process, not just its row.

  `stop_agent/2` used to write `status: :stopped, os_pid: nil` and broadcast. It
  ended nothing — and clearing the pid discarded the only handle anything could
  have acted on, so an agent that survived the "stop" became permanently
  unreachable *by the stop*.

  That is not a hypothetical shape on this project. It shipped three times:
  `Workspaces.Runner.Local` records a pid with no supervisor or monitor, two
  `Task.shutdown(:brutal_kill)` sites leave the OS process detached, and
  `reap_if_absent/3` did the same thing on the reconcile path. All three passed
  everything asked of them, because nothing asked about a process.

  So this one asks about a process. A real one is started, the operator's own
  surface is used to stop it, and the assertion is that it is gone.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Agents.Tools.StopAgent
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Stopping an agent ends the process, not just the record" do
    scenario "Stopping an agent stops the thing that spends money" do
      given_ "an agent running on a working copy, with a process on the machine that serves it",
             context do
        agent = Fixtures.running_agent(context.scope)
        start_agent(agent.id, working_copy: agent.working_copy)

        assert running?(agent.id),
               "the premise is an agent with a live process; without one this " <>
                 "criterion asserts nothing about spending"

        {:ok, context |> Map.put(:agent, agent)}
      end

      when_ "I stop it", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, reply, _frame} = StopAgent.execute(%{"agent_id" => context.agent.id}, frame)

        {:ok, Map.put(context, :reply, reply)}
      end

      then_ "the process on that machine is gone", context do
        refute running?(context.agent.id),
               "the agent was reported stopped and its process is still running. " <>
                 "That is the whole failure: the row says stopped, the model keeps " <>
                 "being called, and the handle that could have reached it has just " <>
                 "been thrown away."

        {:ok, context}
      end

      then_ "and the agent no longer shows as running", context do
        refute context.reply.isError,
               "stopping reported an error: #{response_text(context.reply)}"

        assert response_text(context.reply) =~ ~r/stopped/i

        {:ok, context}
      end
    end
  end
end
