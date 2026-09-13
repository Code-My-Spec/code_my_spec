defmodule CodeMySpecSpex.Story1051.Criterion3209Spex do
  @moduledoc """
  Story 1051 — Harness startup and restart leave the agent working.
  Criterion 3209 — An interrupted agent is told what happened to its work.

  Rule: An agent is told about a restart only when something of its own was in
  flight.

  The agent is the reader here, not a person. It comes back holding the turns
  on its thread and nothing else, and the turn it was part-way through is gone
  — which is what rule `0a06befe` says must happen. That is survivable only if
  the thread says so. Without a line, the agent's own transcript ends mid-tool-
  call and then jumps, and the only readings available to it are "the tool
  never answered" or "I already did this".

  Both halves are asserted separately because they fail separately. A line
  saying the harness restarted, with nothing about the work, tells the agent
  the one thing it could have inferred and withholds the one thing it cannot.

  Read through the conversation page rather than the table, because that is
  where the agent's thread is served from and a row that never reaches it is a
  line nobody reads — and through the transcript region rather than the whole
  document, because the CSRF token is regenerated per render and two identical
  pages compare unequal.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers, only: [restart_harness: 1]
  import CodeMySpecSpex.HarnessLifecycleHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An agent is told about a restart only when something of its own was in flight" do
    scenario "An interrupted agent is told what happened to its work" do
      given_ "an agent waiting on a tool result", context do
        context = given_a_staffed_checkout(context, "spex_3209")
        agent_id = start_agent(context)

        # A turn the server knows is open. That is what makes the agent
        # "interrupted" rather than merely running when the harness goes —
        # and it is the state the restart has to account for.
        :ok = Fixtures.start_turn(context.scope, agent_id)

        path = Fixtures.agent_conversation_path(context.scope, %{id: agent_id})

        {:ok,
         context
         |> Map.put(:agent_id, agent_id)
         |> Map.put(:path, path)
         |> Map.put(:before, transcript(context, path))}
      end

      when_ "the harness restarts", context do
        restart_harness(context.harness_socket)

        {:ok, Map.put(context, :after, transcript(context, context.path))}
      end

      then_ "a line in its conversation says the harness restarted", context do
        refute context.after == context.before,
               """
               Nothing at all was added to the interrupted agent's thread.

               It comes back holding the turns already recorded and no account
               of the one it was in. From inside, that reads either as a tool
               that never answered — so it waits — or as work it has already
               done, so it does not redo it. Both are wrong and neither is
               recoverable from the transcript.
               """

        assert context.after =~ ~r/restart/i,
               """
               Something was added to the thread but it does not say the
               harness restarted, so the agent has a discontinuity and no name
               for it.

               #{context.after}
               """

        {:ok, context}
      end

      then_ "and it says what happened to the work that was in flight", context do
        assert context.after =~ ~r/(in flight|part-way|discard|abandon|unfinished|was doing)/i,
               """
               The agent is told its harness restarted and nothing about the
               turn it was in the middle of.

               That is the half it cannot infer. "The harness restarted" is
               visible from the gap; what the agent needs is whether the work
               it had open survived, and the answer — that a turn in progress
               is discarded and it picks up from the turns already recorded —
               is a decision this project made rather than anything the agent
               can read off its own thread.

               #{context.after}
               """

        {:ok, context}
      end
    end
  end
end
