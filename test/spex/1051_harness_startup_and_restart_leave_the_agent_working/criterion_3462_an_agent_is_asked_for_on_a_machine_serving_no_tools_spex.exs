defmodule CodeMySpecSpex.Story1051.Criterion3462Spex do
  @moduledoc """
  Story 1051 — Harness startup and restart leave the agent working.
  Criterion 3462 — An agent is asked for on a machine serving no tools.

  Rule: An agent whose tools do not resolve fails loudly instead of running.

  Next to 3211 and not the same case. There the resolution *failed*; here it
  succeeded and answered nothing, and an empty answer is the one that gets
  through. `machine_tools/3` folds whatever the copy reports into the role's
  granted set, so a machine serving nothing produces a shorter list rather than
  an error, and the agent starts.

  That is the exact shape of the incident in this story's note. The agent was
  not refused and did not crash; it came up, reported tools, and every call
  failed — for four hours, because nothing anywhere treated "no tools offered"
  as a fault.

  "Names the machinery as the fault" is the assertion that matters, and it is
  why this is not folded into 3211. A refusal saying "could not start" sends
  the operator to restart the agent, which is what made the original incident
  worse. It has to send them to the machine.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers, only: [running?: 1]
  import CodeMySpecSpex.HarnessLifecycleHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CodeMySpec.McpServers.Agents.Tools.StartAgent
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An agent whose tools do not resolve fails loudly instead of running" do
    scenario "An agent is asked for on a machine serving no tools" do
      given_ "a working copy whose machine reports an empty tool list", context do
        context = given_a_staffed_checkout(context, "spex_3462")

        # What a join says when the machine offers nothing. Not an error — the
        # copy answered, and the answer was empty, which is the case that gets
        # through every check there is.
        :ok = Fixtures.record_machine_tools(context.scope, [])

        {:ok, context}
      end

      when_ "an agent is asked for on it", context do
        {:reply, reply, _frame} =
          StartAgent.execute(
            %{role: "coding", working_copy_id: context.copy_id},
            frame(context)
          )

        {:ok,
         context
         |> Map.put(:reply, reply)
         |> Map.put(:text, response_text(reply))
         |> Map.put(:agent_id, agent_id_in(response_text(reply)))}
      end

      then_ "it refuses to start", context do
        assert context.reply.isError,
               """
               An agent was started on a machine offering no tools.

               It will come up, report a tool list, and fail every call it
               makes — indistinguishable from a healthy agent until somebody
               reads a transcript. The story's note measures that at four
               hours.

               #{context.text}
               """

        refute context.agent_id && running?(context.agent_id),
               "the refusal was reported and an agent is running anyway"

        {:ok, context}
      end

      then_ "and it names the machinery as the fault", context do
        assert context.text =~ ~r/(machine|harness|working cop|tool)/i,
               """
               The refusal does not say the machine is the problem.

               That is the whole difference between this and any other refusal:
               an operator told "could not start the agent" restarts the agent,
               and restarting the agent is what made the original incident
               worse. `CheckMachinery` exists because "a fault every agent
               shares is one fault underneath them and restarting them will not
               reach it" — this refusal has to point there.

               #{context.text}
               """

        {:ok, context}
      end
    end
  end
end
