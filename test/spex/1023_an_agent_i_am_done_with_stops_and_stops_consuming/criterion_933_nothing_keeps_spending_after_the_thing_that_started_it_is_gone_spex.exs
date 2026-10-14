defmodule CodeMySpecSpex.Story1023.Criterion933Spex do
  @moduledoc """
  Story 1023 — An agent I am done with stops, and stops consuming.
  Criterion 933 — Nothing keeps spending after the thing that started it is
  gone.

  Rule: An agent's process does not outlive the thing that started it.

  An agent is a supervised process now, not a detached one discovered in an OS
  process table. When the process that was serving it ends without anyone
  deciding to stop the agent — a crash, a kill, a restart of whatever held it
  — nothing is left running against the project, and what the server reports
  as running matches what actually is.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Agents.Tools.ListAgents
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An agent's process does not outlive the thing that started it", criterion: 933 do
    scenario "Nothing keeps spending after the thing that started it is gone" do
      given_ "a Pi agent working on a minted copy", context do
        agent = Fixtures.running_agent(context.scope)
        start_agent(agent.id, working_copy: agent.working_copy)

        assert running?(agent.id),
               "the premise is a live process; without one this criterion asserts " <>
                 "nothing about an orphan surviving it"

        {:ok, context |> Map.put(:agent, agent)}
      end

      when_ "whatever started it goes away — restarted, crashed, or killed", context do
        stop_agent_process(context.agent.id)
        :ok = Fixtures.mark_absent(context.agent)
        {:ok, context}
      end

      then_ "the agent is gone too", context do
        refute running?(context.agent.id),
               "the thing that started the agent is gone and the agent's process is " <>
                 "still there — an orphan left running against the project after " <>
                 "nothing is left to account for it"

        {:ok, context}
      end

      then_ "and no orphan is left running against the subscription", context do
        refute running?(context.agent.id),
               "a process still running with nothing supervising it is exactly the " <>
                 "orphan this criterion exists to rule out"

        {:ok, context}
      end

      then_ "and what is left running matches what is reported as running", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, listing, _frame} = ListAgents.execute(%{}, frame)
        text = response_text(listing)

        [_, status] = Regex.run(~r/Agent: #{context.agent.id}.*?Status: (\w+)/s, text)

        refute status == "running",
               "the agent is still reported running when its process is gone — what " <>
                 "the server says is running has drifted from what actually is. status: " <>
                 status

        {:ok, context}
      end
    end
  end
end
