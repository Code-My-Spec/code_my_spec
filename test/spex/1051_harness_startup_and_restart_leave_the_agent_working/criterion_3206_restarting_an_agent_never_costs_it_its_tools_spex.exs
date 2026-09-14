defmodule CodeMySpecSpex.Story1051.Criterion3206Spex do
  @moduledoc """
  Story 1051 — Harness startup and restart leave the agent working.
  Criterion 3206 — Restarting an agent never costs it its tools.

  Rule: Stopping an agent leaves nothing behind that breaks the next one.

  Several restarts in succession, because that is what actually happened. The
  story's note says agent restarts "made it worse", which is a claim about
  *repetition*: each one was survivable and the sequence was not. A criterion
  that restarts once cannot see that, and one restart is the case least likely
  to fail.

  "No restart leaves it with fewer tools than before" is asserted as a
  monotonic comparison against the run before it, not against a constant. A
  fixed expected count goes stale the next time a tool is added and then this
  criterion is asserting about the constant.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessLifecycleHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CodeMySpec.McpServers.MainAgent.Tools.RestartAgent
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @restarts 3

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Stopping an agent leaves nothing behind that breaks the next one" do
    scenario "Restarting an agent never costs it its tools" do
      given_ "an agent is restarted several times in succession", context do
        context = given_a_staffed_checkout(context, "spex_3206")
        agent_id = start_agent(context)

        Fixtures.authored_story(context.scope, "a story the agent's tools can find")

        {:ok,
         context
         |> Map.put(:agent_id, agent_id)
         |> Map.put(:before, carried_tools(agent_id))}
      end

      when_ "it calls a tool after each restart", context do
        rounds =
          Enum.map(1..@restarts, fn n ->
            {:reply, reply, _frame} =
              RestartAgent.execute(
                %{agent_id: context.agent_id, reason: "restart #{n} of #{@restarts}"},
                frame(context)
              )

            %{
              n: n,
              refused: reply.isError,
              reply: response_text(reply),
              call: tool_call(context.agent_id),
              tools: carried_tools(context.agent_id)
            }
          end)

        {:ok, Map.put(context, :rounds, rounds)}
      end

      then_ "every call resolves", context do
        failed = Enum.reject(context.rounds, &match?({:ok, _}, &1.call))

        assert failed == [],
               """
               #{length(failed)} of #{@restarts} restarts left the agent unable to
               call a tool.

               Restarting is the remedy an operator reaches for first, and one
               that costs the agent its tools makes every subsequent restart
               look like a deeper fault — which is why restarting made the
               original incident worse instead of clearing it.

               #{Enum.map_join(failed, "\n", &"restart #{&1.n}: #{inspect(&1.call)}")}
               """

        {:ok, context}
      end

      then_ "and no restart leaves it with fewer tools than before", context do
        {shrunk, _} =
          Enum.reduce(context.rounds, {[], context.before}, fn round, {lost, previous} ->
            {note_shrinkage(previous -- round.tools, round.n, lost), round.tools}
          end)

        assert shrunk == [],
               """
               A restart came back with fewer tools than the agent had going
               into it.

               This is the failure that hides: the agent is running, it is
               answering, and the thing it can no longer do is whatever lived
               behind the tool that went missing. Nobody is told, because from
               the agent's side a shorter list is indistinguishable from a
               correct one.

               #{inspect(Enum.reverse(shrunk))}
               """

        {:ok, context}
      end
    end
  end

  # Nothing missing this round, so nothing to report about it.
  defp note_shrinkage([], _n, lost), do: lost
  defp note_shrinkage(missing, n, lost), do: [{n, missing} | lost]
end
