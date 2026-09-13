defmodule CodeMySpecSpex.Story1051.Criterion3468Spex do
  @moduledoc """
  Story 1051 — Harness startup and restart leave the agent working.
  Criterion 3468 — An agent is restarted part-way through a turn.

  Rule: A turn in progress is discarded on restart; the agent picks up from the
  turns already recorded.

  The rule used to read "work in flight when the harness restarts resumes
  rather than being abandoned", which contradicted story 1015's criterion 3321
  outright. It was reworded during this story's Three Amigos, and this
  criterion is the first half of the new wording: the recorded turns survive,
  the one in progress does not.

  Discarding is the cheap half and the surviving history is the half that
  fails quietly. An agent brought back with an empty thread is running,
  answering, and has forgotten the story it was part-way through — which looks
  like success from every angle except the one that matters, and costs the work
  rather than the process. `Agents.restart_agent/2` hydrates the launch request
  from the conversation for exactly this reason.

  Asked of the agent's own loop rather than of its transcript. The page renders
  the rows either way: an agent that came back holding its history and one that
  came back empty show the same conversation, and the difference only appears
  when somebody relies on it remembering.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers, only: [agent_knows?: 2, running?: 1]
  import CodeMySpecSpex.HarnessLifecycleHelpers

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
    scenario "An agent is restarted part-way through a turn" do
      given_ "an agent mid-turn when it is restarted", context do
        context = given_a_staffed_checkout(context, "spex_3468")
        agent_id = start_agent(context)
        agent = %{id: agent_id, role: :coding}

        # Turns already on the thread — what must survive.
        :ok = Fixtures.agent_said(context.scope, agent, "half of the ledger writer is done")

        # And one in progress, which must not.
        :ok = Fixtures.start_turn(context.scope, agent_id)

        {:ok, context |> Map.put(:agent_id, agent_id) |> Map.put(:agent, agent)}
      end

      when_ "it comes back", context do
        {:reply, reply, _frame} =
          RestartAgent.execute(
            %{agent_id: context.agent_id, reason: "the harness went underneath it"},
            frame(context)
          )

        refute reply.isError, "the premise is an agent that came back, and this one did not"

        {:ok, context}
      end

      then_ "it carries on from the turns already recorded on its thread", context do
        assert running?(context.agent_id),
               "the agent did not come back, so there is nothing to carry on from"

        assert agent_knows?(context.agent_id, "half of the ledger writer is done"),
               """
               The agent came back with no memory of what it was doing.

               Running and having forgotten is worse than not coming back: it
               looks like success from every angle except the one that matters,
               and what is lost is the work rather than the process. An agent
               restored into an empty thread starts the story again from the
               beginning — or, worse, starts something else.
               """

        {:ok, context}
      end

      then_ "and the turn it was in is gone", context do
        refute listing(context) =~ ~r/Status: starting/,
               """
               The agent is left in the state the restart was supposed to move
               it out of.

               `restart_agent/2` clears `turn_started_at` precisely so nothing
               goes on reporting a turn that opened before the process it
               belonged to was killed. A row left mid-turn is one nothing will
               ever clear.

               #{listing(context)}
               """

        {:ok, context}
      end
    end
  end
end
