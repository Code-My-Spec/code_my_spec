defmodule CodeMySpecSpex.Story1023.Criterion2879Spex do
  @moduledoc """
  Story 1023 — An agent I am done with stops, and stops costing.
  Criterion 2879 — Two lanes on one copy, one of them stopped.

  Rule: Stopping one agent leaves every other agent on that working copy
  running.

  A working copy runs a team, not an agent. They share a root, a conversation
  and a harness, and the only thing separating them is the lane's role — so a
  stop that reaps by working copy, or by killing a process tree that happens to
  contain a sibling, takes out the agent nobody asked to stop.

  That failure is silent from the caller's side: the stop it asked for
  succeeded. The reason the group is per agent rather than per copy is exactly
  this.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Agents.Tools.StopAgent
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  @copy "/tmp/one-copy-two-lanes"

  spex "One lane stops without taking its team with it" do
    scenario "Two lanes on one copy, one of them stopped" do
      given_ "a working copy running a coding lane and a QA lane", context do
        coding_process = start_process()
        qa_process = start_process()

        coding =
          Fixtures.running_agent(context.scope, coding_process,
            role: "coding",
            working_copy: @copy
          )

        qa =
          Fixtures.running_agent(context.scope, qa_process, role: "qa", working_copy: @copy)

        assert coding.working_copy == qa.working_copy,
               "the premise is two lanes on the *same* copy; on different copies " <>
                 "this asserts nothing about reaping by working copy"

        {:ok,
         context
         |> Map.put(:coding, coding)
         |> Map.put(:qa, qa)
         |> Map.put(:coding_process, coding_process)
         |> Map.put(:qa_process, qa_process)}
      end

      when_ "I stop the QA lane", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, reply, _frame} = StopAgent.execute(%{"agent_id" => context.qa.id}, frame)
        {:ok, Map.put(context, :reply, reply)}
      end

      then_ "the coding lane is still running and still on that copy", context do
        refute context.reply.isError

        assert in_group(context.coding_process.os_pid) != [],
               "stopping the QA lane killed the coding lane too. They share a copy, " <>
                 "a root and a conversation, so a stop that reaps by working copy " <>
                 "takes out the agent nobody asked about — and the caller is told " <>
                 "its stop succeeded."

        {:ok, context}
      end

      then_ "and only the QA lane's process is gone", context do
        assert in_group(context.qa_process.os_pid) == [],
               "the lane that was asked to stop is still running"

        {:ok, context}
      end
    end
  end
end
