defmodule CodeMySpecSpex.Story1056.Criterion3306Spex do
  @moduledoc """
  Story 1056 — The main agent starts, stops and restarts its agents.
  Criterion 3306 — The main agent restarts an agent and nothing else.

  Rule: the blast radius of a remedy is the thing it was aimed at.

  `StopAgent` already says this about stopping, in its own words: "a stop that
  reaps the whole tree, or kills by name and catches a sibling, is
  indistinguishable from this one at the call site and is worse than having no
  stop at all — the agents left alone are the point." Restarting inherits the
  same rule and needs it more, because the main agent restarts on its own
  judgement and will do it far more often than a person would.

  The failure is invisible from the call site. The restart succeeds, the
  intended agent comes back, and the reply says so — while a sibling that was
  mid-turn has silently lost it. Nothing reports that; the sibling simply
  appears to have gone quiet, which reads as a stall, which invites another
  restart.

  ## What the scenario watches

  A second agent, on the same checkout, mid-turn. The same checkout on purpose:
  agents that share a copy share a harness, and "restart" implemented one layer
  too high takes the harness and everything on it — which is 3307's territory
  from the other direction. The turn in flight is what makes the damage
  observable, because a turn is the thing a restart destroys.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
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

  spex "One agent restarts and its neighbour keeps working" do
    scenario "two agents share a checkout and one needs restarting" do
      given_ "an agent to restart and a neighbour mid-turn on the same checkout",
             context do
        reply = join_working_copy(context, "/tmp/spex-3306", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        # The provider these agents run on — `running_agent/2` defaults to zai.
        # `Agents.restart_agent/2`
        # resolves one before it attempts anything — deliberately, so a restart
        # fails here rather than minutes later on the agent's first model call.
        {:ok, _integration} = CodeMySpecSpex.Fixtures.connect_provider(scope, :zai)

        target = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-3306")
        neighbour = Fixtures.running_agent(scope, role: "qa", working_copy: "/tmp/spex-3306")

        # Mid-turn, which is what a careless restart destroys — and the only
        # state in which the damage is observable at all.
        :ok = Fixtures.start_turn(scope, neighbour.id)

        {:ok,
         context
         |> Map.put(:scope, scope)
         |> Map.put(:target, target)
         |> Map.put(:neighbour, neighbour)}
      end

      when_ "the main agent restarts one of them", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          RestartAgent.execute(
            %{agent_id: context.target.id, reason: "it stopped answering"},
            frame
          )

        refute response.isError, inspect(response)

        {:reply, view, _frame} = ListAgentWork.execute(%{}, frame)

        {:ok, Map.put(context, :view, response_text(view))}
      end

      then_ "the neighbour's work is untouched", context do
        neighbour_entry = entry_for(context.view, context.neighbour.id)

        assert neighbour_entry,
               """
               The neighbouring agent is gone from the fleet entirely after a
               restart aimed at somebody else.

               view:
               #{context.view}
               """

        refute neighbour_entry =~ ~r/in flight:[^\n]*(nothing|none|no turn)/i,
               """
               A restart aimed at one agent took its neighbour's turn with it.

               This is invisible from the call site: the restart succeeded, the
               intended agent came back, and the reply said so. The neighbour
               simply appears to have gone quiet — which reads as a stall, which
               invites another restart.

               `stop_agent` already carries this rule for stopping: the agents
               left alone are the point. Restarting needs it more, because the
               main agent does it on its own judgement and far more often than a
               person would.

               neighbour:
               #{neighbour_entry}
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
