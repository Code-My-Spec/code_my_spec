defmodule CodeMySpecSpex.Story1051.Criterion3210Spex do
  @moduledoc """
  Story 1051 — Harness startup and restart leave the agent working.
  Criterion 1192 — An idle agent is told nothing when the harness restarts.

  Rule: An agent caught mid-turn is told its harness restarted; a stopped
  agent is told nothing.

  A stopped agent lost nothing to a restart: its conversation is resumed as
  recorded and it has no turn to carry on. A line saying the harness restarted
  is noise on its thread, and a menu with it is a nudge to take a turn nobody
  asked for — on every agent, on every restart.

  Read as what the agent has been told: the transcript region plus anything
  waiting to reach it, since a message sent to an agent sits pending until its
  engine takes it.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers, only: [restart_harness: 1]
  import CodeMySpecSpex.HarnessLifecycleHelpers

  alias CmsHarnessTest.Machine
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An agent caught mid-turn is told its harness restarted; a stopped agent is told nothing.",
    criterion: 1192 do
    scenario "An idle agent is told nothing when the harness restarts" do
      given_ "an agent that is idle with nothing in flight", context do
        context = given_a_feature_checkout(context, "spex_1192")
        agent_id = start_agent(context)

        # Idle is the premise, so it is checked rather than assumed. An agent
        # that happened to be mid-turn here would be told, rightly.
        assert {:ok, %{busy?: false}} = Machine.status(agent_id),
               "the premise is an idle agent, and this one is working"

        path = Fixtures.agent_conversation_path(context.scope, %{id: agent_id})

        {:ok,
         context
         |> Map.put(:agent_id, agent_id)
         |> Map.put(:path, path)
         |> Map.put(:before, told(context, path))}
      end

      when_ "the harness restarts", context do
        restart_harness(context.harness_socket)

        {:ok, Map.put(context, :after, told(context, context.path))}
      end

      then_ "nothing is added to its conversation, and nothing is sent to it", context do
        assert context.after == context.before,
               """
               A stopped agent was told something about a restart that cost it
               nothing.

               before:
               #{context.before}

               after:
               #{context.after}
               """

        {:ok, context}
      end
    end
  end
end
