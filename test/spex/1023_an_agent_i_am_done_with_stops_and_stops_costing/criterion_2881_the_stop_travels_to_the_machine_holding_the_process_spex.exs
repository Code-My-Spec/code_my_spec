defmodule CodeMySpecSpex.Story1023.Criterion2881Spex do
  @moduledoc """
  Story 1023 — An agent I am done with stops, and stops costing.
  Criterion 2881 — The stop travels to the machine holding the process.

  Rule: The machine the process is on is what ends it; the server only asks.

  Deliberately uses one path for both copies. Two machines share a root
  constantly — every container sits at `/workspace/app` — and a stop that
  resolved its target by matching path strings would end the wrong agent while
  telling the caller it succeeded. That is the same premise story 1020's
  criterion 2843 is built on, one level down.

  What is asserted here is the outcome: only the targeted agent's group is
  ended, and the other machine's is untouched. The routing itself — the server
  looking the copy up in `HarnessRegistry` and pushing to that channel — is
  driven end to end by `CodeMySpecWeb.AgentStopRoundTripTest`, which asserts the
  push as it leaves and feeds the reply back through the real handler. Said here
  because a spex asserting an outcome should say where the mechanism is proven
  rather than imply it proves it.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Agents.Tools.StopAgent
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project


  spex "A stop ends the process on the machine it named" do
    scenario "The stop travels to the machine holding the process" do
      given_ "two machines each running an agent with the same role on a copy at the same path",
             context do
        # Both agents name the same checkout — that is the premise. It has to
        # exist because starting an agent on a missing one is refused, and it
        # cannot be a plausible-looking constant: `/workspace/app` is not
        # writable on the machine these run on.
        shared_path = CodeMySpec.TempFile.dir("spex_2881_shared")
        File.mkdir_p!(shared_path)

        on_this_machine =
          Fixtures.running_agent(context.scope,
            role: "coding",
            working_copy: shared_path
          )

        on_that_machine =
          Fixtures.running_agent(context.scope,
            role: "coding",
            working_copy: shared_path
          )

        start_agent(on_this_machine.id, working_copy: shared_path)
        start_agent(on_that_machine.id, working_copy: shared_path)

        assert on_this_machine.working_copy == on_that_machine.working_copy,
               "the premise is a shared path; with different paths a stop that " <>
                 "matched on the string would pass and prove nothing"

        refute on_this_machine.id == on_that_machine.id,
               "identity is the only thing that separates these two, which is " <>
                 "exactly what the stop has to match on"

        {:ok,
         context
         |> Map.put(:target, on_this_machine)
         |> Map.put(:here, on_this_machine)
         |> Map.put(:elsewhere, on_that_machine)
         |> Map.put(:other, on_that_machine)}
      end

      when_ "I stop the agent on one of them", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, reply, _frame} = StopAgent.execute(%{"agent_id" => context.target.id}, frame)
        {:ok, Map.put(context, :reply, reply)}
      end

      then_ "only that machine's process is ended", context do
        refute context.reply.isError

        refute running?(context.here.id),
               "the agent that was asked to stop is still running"

        {:ok, context}
      end

      then_ "and the other machine's agent is untouched", context do
        assert running?(context.elsewhere.id),
               "stopping one agent ended another that merely shares its path and " <>
                 "role. Every container sits at /workspace/app, so a stop resolving " <>
                 "its target by path ends somebody else's agent and reports success."

        {:ok, context}
      end
    end
  end
end
