defmodule CodeMySpecSpex.Story1051.Criterion3468Spex do
  @moduledoc """
  Story 1051 — Harness startup and restart leave the agent working.
  Criterion 1391 — An agent is restarted part-way through a turn.

  Rule: A restart resumes the conversation as recorded; an agent caught
  mid-turn carries its turn on before anything queued is delivered.

  The surviving history is the half that fails quietly. An agent brought back
  with an empty thread is running, answering, and has forgotten the story it
  was part-way through — which looks like success from every angle except the
  one that matters. `Agents.restart_agent/2` hydrates the launch request from
  the conversation for exactly this reason.

  Asked of the agent's own loop rather than of its transcript: the page renders
  the rows either way, and the difference only appears when somebody relies on
  it remembering. The carry-on is read from what has been sent to the agent.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.AgentProcessHelpers, only: [agent_knows?: 2, running?: 1]
  import CodeMySpecSpex.HarnessLifecycleHelpers
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A restart resumes the conversation as recorded; an agent caught mid-turn carries its turn on before anything queued is delivered",
    criterion: 1391 do
    scenario "An agent is restarted part-way through a turn" do
      given_ "an agent mid-turn when it is restarted", context do
        context = given_a_feature_checkout(context, "spex_3468")
        agent_id = start_agent(context)
        agent = %{id: agent_id, role: :coding}

        # The conversation so far — what must survive.
        :ok = Fixtures.agent_said(context.scope, agent, "half of the ledger writer is done")

        # And a turn in progress, which must carry on.
        :ok = Fixtures.start_turn(context.scope, agent_id)

        {:ok, context |> Map.put(:agent_id, agent_id) |> Map.put(:agent, agent)}
      end

      when_ "it comes back", context do
        reply =
          ToolLibrary.run(
            "restart_agent",
            %{agent_id: context.agent_id, reason: "the harness went underneath it"},
            Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
          )

        assert match?({:ok, _}, reply),
               "the premise is an agent that came back, and this one did not"

        {:ok, context}
      end

      then_ "it holds its conversation as recorded", context do
        assert running?(context.agent_id),
               "the agent did not come back, so there is nothing to carry on from"

        assert agent_knows?(context.agent_id, "half of the ledger writer is done"),
               """
               The agent came back with no memory of what it was doing.

               Running and having forgotten is worse than not coming back: it
               looks like success from every angle except the one that matters,
               and what is lost is the work rather than the process.
               """

        {:ok, context}
      end

      then_ "and it carries the turn on from its last recorded step", context do
        path = Fixtures.agent_conversation_path(context.scope, context.agent)

        assert told(context, path) =~ "Carry on from your last step",
               """
               The restart cut the agent's turn and nothing told it to carry
               on, so it sits idle with the work half done.

               #{told(context, path)}
               """

        refute listing(context) =~ ~r/Status: starting/,
               "the agent is left in the state the restart was supposed to move it out of"

        {:ok, context}
      end
    end
  end
end
