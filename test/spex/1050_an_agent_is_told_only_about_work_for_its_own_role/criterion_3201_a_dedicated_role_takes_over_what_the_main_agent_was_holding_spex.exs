defmodule CodeMySpecSpex.Story1050.Criterion3201Spex do
  @moduledoc """
  Story 1050 — An agent is told only about work for its own role.
  Criterion 3201 — A dedicated role takes over what the main agent was holding.

  3200's other half, and the one that says the main agent's claim on unroled
  work is a default rather than an assignment. Without this, adding a devops
  role later would give the project two agents told about the same work — and
  the main agent, being the one with project scope, would keep acting on it.

  It is also a statement about the routing rule's shape. "Send devops work to
  main" written as a rule about *devops* is a rule that has to be found and
  changed when the role arrives. The rule that survives is about roles: work
  goes to the role that owns it, and to main only when that role has no agent.
  Stated that way, 3200 and this are the same rule evaluated against different
  fleets.

  ## This will fail before it can be written

  `Agent`'s role enum is `[:main, :product, :coding, :qa]`. There is no devops
  role to declare, so the premise cannot be established — which is the correct
  red bar for this criterion rather than a reason to weaken it. The
  implementation that satisfies this adds the role; a spec that worked around
  its absence would be asserting about something else.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [agent_id_in: 1]
  import CodeMySpecSpex.IdleAgentHelpers
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CodeMySpec.McpServers.Agents.Tools.StartAgent
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Work whose role does not exist goes to the main agent" do
    scenario "A dedicated role takes over what the main agent was holding" do
      given_ "the project chain is past kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ "a devops agent with devops as its declared role", context do
        main = Fixtures.running_agent(context.scope, role: "main")
        context = context |> start_session() |> put_to_work()
        :ok = Fixtures.watch_graph(context.scope)

        # Through the tool rather than the fixture, so the absence of the role
        # is reported rather than raised. `Agent`'s enum is `[:main, :product,
        # :coding, :qa]` today, and a bare `MatchError` from a fixture says
        # nothing about which of this criterion's two claims is unmet.
        {:reply, started, _frame} =
          StartAgent.execute(
            %{role: "devops", working_copy_id: context.scope.active_working_copy_id},
            frame(context)
          )

        refute started.isError,
               """
               There is no devops role to declare, so this criterion's premise
               cannot be built.

               That is the correct red bar rather than a reason to weaken the
               spec: what satisfies this criterion is adding the role. A
               version that worked around its absence would be asserting about
               something else.

               #{response_text(started)}
               """

        {:ok,
         context
         |> Map.put(:main, main.id)
         |> Map.put(:devops, agent_id_in(response_text(started)))
         |> Map.put(:main_before, heard_count(context, main.id))
         |> Map.put(:devops_before, 0)}
      end

      when_ "devops work appears on the project", context do
        :ok = Fixtures.enable_devops(context.scope)
        :ok = Fixtures.settle_graph(context.scope)

        {:ok, context}
      end

      then_ "the devops agent is told about it", context do
        assert heard_count(context, context.devops) > context.devops_before,
               """
               The role that owns this work exists and was not told about it.

               The rule that survives the arrival of a new role is about roles
               rather than about devops: work goes to the role that owns it,
               and to main only when that role has no agent. A rule written the
               other way has to be found and changed the day the role is added.
               """

        {:ok, context}
      end

      then_ "and the main agent is not told about it", context do
        refute_told_anything(
          context,
          context.main,
          context.main_before,
          """
          The main agent is still being told about work a dedicated role now
          owns.

          Two agents told about the same work is worse than either one alone,
          and the main agent — the one with project scope — is the one that
          will keep acting on it. Its claim on unroled work has to be a default
          it gives up, not an assignment it keeps.
          """
        )

        {:ok, context}
      end
    end
  end
end
