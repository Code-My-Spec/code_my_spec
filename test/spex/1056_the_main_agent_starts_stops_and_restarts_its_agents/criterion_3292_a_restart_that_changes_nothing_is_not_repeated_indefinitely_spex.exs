defmodule CodeMySpecSpex.Story1056.Criterion3292Spex do
  @moduledoc """
  Story 1056 — The main agent starts, stops and restarts its agents.
  Criterion 3292 — A restart that changes nothing is not repeated indefinitely.

  Rule: a remedy that has not worked twice is not a remedy.

  The story's own note is the reason this exists: over one session the only
  actions that changed anything were restarts — six of an agent, one of the
  harness — and restarting was also what *caused* one outage. An agent that can
  restart and cannot stop restarting has a loop with a cost, and the cost is
  paid in discarded turns and model spend by the agent least able to complain
  about it.

  Six is the observed number and it was a person doing it by hand, who at least
  got bored. Nothing here gets bored.

  ## The refusal is not the point on its own

  "And the situation is raised instead of retried" is half the criterion and the
  more important half. A main agent that silently declines to restart leaves an
  agent broken with nobody told — which is worse than the loop, because the loop
  is at least visible. So both are asserted: the restart does not happen, and
  something is raised that a person will see.

  Distinct from 3308, which is about a fault surviving *one* restart. This is
  about the main agent's own behaviour after several, and it fails differently:
  3308 fails by staying quiet, this one fails by trying again.

  ## Keyed on the reason, not the count

  Three restarts for three different faults is a busy morning. The scenario
  restarts for the *same* reason each time, which is what makes it a loop —
  criterion 3291 is what makes that distinction expressible at all.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.ListIssues
  alias CodeMySpec.McpServers.MainAgent.Tools.RestartAgent
  alias Ecto.Adapters.SQL.Sandbox

  @reason "its tools stopped resolving after the harness reconnected"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The same restart is not tried forever" do
    scenario "three restarts for one reason have each left the agent as it was" do
      given_ "an agent restarted three times for the same reason, still broken",
             context do
        reply = join_working_copy(context, "/tmp/spex-3292", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        agent =
          CodeMySpecSpex.Fixtures.running_agent(scope,
            role: "coding",
            working_copy: "/tmp/spex-3292"
          )

        # Broken before, broken after, and still broken now. Nothing clears it
        # between restarts, which is what makes them changes that changed
        # nothing.
        CodeMySpecSpex.Fixtures.record_machine_tools(scope, [])

        frame = %Frame{assigns: %{current_scope: scope}}

        for _attempt <- 1..3 do
          {:reply, response, _frame} =
            RestartAgent.execute(%{agent_id: agent.id, reason: @reason}, frame)

          response
        end

        {:ok, context |> Map.put(:scope, scope) |> Map.put(:agent, agent)}
      end

      when_ "the main agent considers restarting it again", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          RestartAgent.execute(%{agent_id: context.agent.id, reason: @reason}, frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "it does not", context do
        assert context.response.isError,
               """
               A fourth restart went ahead for a reason three restarts have
               already failed to fix.

               Nothing stops this. A person doing it by hand got to six and
               stopped because they got bored; nothing here gets bored, and the
               cost is paid in discarded turns and model spend by the agent
               least able to complain about it.

               reply:
               #{response_text(context.response)}
               """

        {:ok, context}
      end

      then_ "and the situation is raised instead", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, issues, _frame} = ListIssues.execute(%{}, frame)

        assert response_text(issues) =~ @reason,
               """
               The main agent stopped restarting and told nobody.

               This is the worse half of the failure. A silent refusal leaves an
               agent broken with no loop to notice and no issue to read — at
               least the loop was visible. "Raised instead of retried" is the
               criterion, and the refusal on its own is only the first word of
               it.

               issues:
               #{response_text(issues)}
               """

        {:ok, context}
      end
    end
  end
end
