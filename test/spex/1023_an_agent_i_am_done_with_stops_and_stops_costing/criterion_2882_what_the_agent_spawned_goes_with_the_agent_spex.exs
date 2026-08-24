defmodule CodeMySpecSpex.Story1023.Criterion2882Spex do
  @moduledoc """
  Story 1023 — An agent I am done with stops, and stops costing.
  Criterion 2882 — What the agent spawned goes with the agent.

  Rule: An agent runs in its own process group, and that group is what gets
  signalled.

  An agent is not one process. It runs compilers, test suites, `git`, and
  whatever a tool asks for — and those are the expensive ones. Killing only the
  process we launched leaves them holding the working copy open and, when they
  are the thing burning the subscription, still burning it.

  `Workspaces.Runner.Local` reaps with `pkill -TERM -P` and its own comment
  concedes it does "not walk past one level of children", so a grandchild
  survives. A group is the whole tree in one signal, with no walking.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Agents.Tools.StopAgent
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The group is the unit, not the pid" do
    scenario "What the agent spawned goes with the agent" do
      given_ "a running agent that has spawned its own child processes", context do
        process = start_process(children: 2)
        agent = Fixtures.running_agent(context.scope, process)

        assert length(await_group(process.os_pid, 3)) >= 3,
               "the premise is an agent with children; with one process this cannot " <>
                 "tell a group signal from a single kill"

        {:ok, context |> Map.put(:agent, agent) |> Map.put(:process, process)}
      end

      when_ "I stop it", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, reply, _frame} = StopAgent.execute(%{"agent_id" => context.agent.id}, frame)
        {:ok, Map.put(context, :reply, reply)}
      end

      then_ "the agent and every process it spawned are gone", context do
        assert in_group(context.process.os_pid) == [],
               "processes the agent spawned outlived the stop. Those are the " <>
                 "expensive ones — a compiler or a test run — and they are what a " <>
                 "reap that walks one level of children leaves behind."

        {:ok, context}
      end

      then_ "and nothing is left holding the working copy open", context do
        refute context.reply.isError

        assert in_group(context.process.os_pid) == []

        {:ok, context}
      end
    end
  end
end
