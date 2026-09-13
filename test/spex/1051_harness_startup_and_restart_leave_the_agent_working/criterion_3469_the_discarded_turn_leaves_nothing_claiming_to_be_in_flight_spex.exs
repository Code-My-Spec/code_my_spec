defmodule CodeMySpecSpex.Story1051.Criterion3469Spex do
  @moduledoc """
  Story 1051 — Harness startup and restart leave the agent working.
  Criterion 3469 — The discarded turn leaves nothing claiming to be in flight.

  Rule: A turn in progress is discarded on restart; the agent picks up from the
  turns already recorded.

  3468 says the agent comes back without the turn. This says the *rest of the
  system* comes back without it too, and they are not the same claim: the turn
  lives in the process and in a column, and discarding it in one place leaves
  the other asserting it.

  That happened and was measured (`4078e7bf`): `list_agent_work` and every
  check-in went on reporting "a turn opened at <then> and has not finished" for
  an agent that had been restarted and whose process was gone — two minutes
  past the restart and still climbing, against a row nothing would ever clear.

  The cost is specific. The main agent decides whether to intervene from this
  reading, so a turn that never closes is an agent that looks permanently busy:
  never stalled enough to restart, never idle enough to be given work. It just
  stops being asked.

  Driven through `list_agent_work` because "anything asks what that agent is
  working on" is that tool — it is the surface the main agent and the cadence
  both read.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessLifecycleHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CodeMySpec.McpServers.MainAgent.Tools.ListAgentWork
  alias CodeMySpec.McpServers.MainAgent.Tools.RestartAgent
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A turn in progress is discarded on restart; the agent picks up from the turns already recorded" do
    scenario "The discarded turn leaves nothing claiming to be in flight" do
      given_ "an agent restarted part-way through a turn", context do
        context = given_a_staffed_checkout(context, "spex_3469")
        agent_id = start_agent(context)

        :ok = Fixtures.start_turn(context.scope, agent_id)

        {:reply, view, _frame} = ListAgentWork.execute(%{}, frame(context))

        assert entry_for(response_text(view), agent_id) =~ "has not finished",
               """
               The premise is an agent with a turn open, and nothing reports one
               — so what follows would be about an agent that was never mid-turn.

               #{response_text(view)}
               """

        {:reply, reply, _frame} =
          RestartAgent.execute(
            %{agent_id: agent_id, reason: "the harness went underneath it"},
            frame(context)
          )

        refute reply.isError, "the premise is an agent that was restarted"

        {:ok, Map.put(context, :agent_id, agent_id)}
      end

      when_ "anything asks what that agent is working on", context do
        {:reply, view, _frame} = ListAgentWork.execute(%{}, frame(context))

        {:ok, Map.put(context, :view, response_text(view))}
      end

      then_ "no turn is reported as open", context do
        entry = entry_for(context.view, context.agent_id)

        assert entry,
               """
               The agent is gone from the fleet listing entirely after a
               restart, so "no turn is open" is true of nothing.

               #{context.view}
               """

        refute entry =~ "has not finished",
               """
               The abandoned turn is still being reported as running.

               The process it belonged to is gone and nothing will ever close
               the row, so this reading only gets older. Measured at two
               minutes past a restart and still climbing (`4078e7bf`).

               What it costs is the main agent's judgement: it decides whether
               to intervene from exactly this line, and an agent that looks
               permanently mid-turn is never stalled enough to restart and
               never idle enough to be given work. It simply stops being asked.

               #{entry}
               """

        {:ok, context}
      end
    end
  end

  defp entry_for(view, agent_id) do
    view
    |> String.split(~r/\n(?=\s*Agent:)/)
    |> Enum.find(&String.contains?(&1, agent_id))
  end
end
