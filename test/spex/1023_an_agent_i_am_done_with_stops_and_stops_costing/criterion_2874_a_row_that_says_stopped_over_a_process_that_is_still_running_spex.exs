defmodule CodeMySpecSpex.Story1023.Criterion2874Spex do
  @moduledoc """
  Story 1023 — An agent I am done with stops, and stops costing.
  Criterion 2874 — A row that says stopped over a process that is still running.

  Rule: Stopping an agent ends its process, not just its row.

  The failure mode with a cost attached. A stop that reports success without
  ending anything leaves an agent calling a model with nothing watching it — and
  because the old implementation also cleared `os_pid`, it left nothing able to
  reach the survivor either.

  So a machine this server cannot talk to must not produce a stop. The operator
  is told which of the two it is, because the remedies differ entirely:
  "reconnect that box" is not "your agent is gone".
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Agents.Tools.ListAgents
  alias CodeMySpec.McpServers.Agents.Tools.StopAgent
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A stop that could not happen is not reported as one" do
    scenario "A row that says stopped over a process that is still running" do
      given_ "an agent whose process cannot be ended — its machine is unreachable", context do
        process = start_process()
        agent = Fixtures.running_agent(context.scope, process)

        machine_out_of_reach()

        {:ok, context |> Map.put(:agent, agent) |> Map.put(:process, process)}
      end

      when_ "I stop it", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, reply, _frame} = StopAgent.execute(%{"agent_id" => context.agent.id}, frame)
        {:ok, Map.put(context, :reply, reply)}
      end

      then_ "it is not reported as stopped", context do
        assert context.reply.isError,
               "the machine could not be reached and the stop reported success. " <>
                 "The process is still running, still spending, and the row now " <>
                 "says otherwise."

        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, listing, _frame} = ListAgents.execute(%{}, frame)

        assert response_text(listing) =~ context.agent.id,
               "the agent was dropped from the listing despite nothing having " <>
                 "stopped it, which is how a live process becomes one nobody is " <>
                 "looking for"

        {:ok, context}
      end

      then_ "and I am told the machine could not be reached, rather than that the agent is gone",
            context do
        text = response_text(context.reply)

        assert text =~ ~r/connect|reach|machine|harness/i,
               "the refusal does not say the machine was unreachable, so the " <>
                 "reader cannot tell 'reconnect that box' from 'this agent is " <>
                 "already gone'. Got: #{text}"

        {:ok, context}
      end
    end
  end
end
