defmodule CodeMySpecSpex.Story1056.Criterion3307Spex do
  @moduledoc """
  Story 1056 — The main agent starts, stops and restarts its agents.
  Criterion 3307 — The main agent cannot restart the harness to fix an agent.

  Rule: the main agent's reach stops at the project it owns.

  The criterion states its own cost: restarting the harness kills in-flight work
  for every working copy on the machine, including other projects. One agent's
  fault is not a licence to do that, and the main agent is exactly the party
  most likely to reach for it — it can see that a harness restart would clear
  the fault, because the observed outage was cleared by one.

  That is what makes this a refusal rather than an omission. The remedy works.
  It is simply not this agent's to apply, because the agent that would benefit
  can see only its own project and the cost falls on projects it cannot see.

  ## Both halves are asserted

  Refusing alone leaves an agent broken and nobody told, which is the same
  failure 3292 names. So the fault has to be raised — something a person will
  read, naming what would fix it — and that is the whole value of the refusal:
  it converts an action the main agent must not take into a decision somebody
  who can take it will see.

  ## Why the scenario asks through the restart tool

  There is no harness-restart tool for the main agent to call, and this
  criterion is why there must not be. Asking for one by naming a machine rather
  than an agent is the closest thing to the attempt the criterion describes, and
  it is the shape a well-meaning implementation would grow first — a `scope:` or
  `target:` option on the tool that already exists.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.ListIssues
  alias CodeMySpec.McpServers.MainAgent.Tools.RestartAgent
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A fault that needs the harness is raised, not acted on" do
    scenario "an agent's fault would be cleared by restarting its harness" do
      given_ "an agent whose harness is the thing at fault", context do
        reply = join_working_copy(context, "/tmp/spex-3307", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        agent = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-3307")

        # The machine answers that it can run nothing, which is the harness's
        # MCP client and not the agent — restarting the agent will not touch it.
        Fixtures.record_machine_tools(scope, [])

        {:ok,
         context
         |> Map.put(:scope, scope)
         |> Map.put(:agent, agent)
         |> Map.put(:working_copy_id, reply.working_copy_id)}
      end

      when_ "the main agent tries to restart the harness instead of the agent",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          RestartAgent.execute(
            %{
              agent_id: context.working_copy_id,
              reason: "the harness is holding a dead MCP client"
            },
            frame
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "it cannot", context do
        assert context.response.isError,
               """
               The main agent restarted something that is not one of its agents.

               A harness serves every working copy on the machine, including
               other projects', and restarting it kills their in-flight work
               too. The main agent can see that doing so would clear this fault
               — the observed outage was cleared exactly that way — which is
               what makes it the party most likely to reach for it and why this
               has to be a refusal rather than an omission.

               reply:
               #{response_text(context.response)}
               """

        {:ok, context}
      end

      then_ "and the fault is raised for somebody who can act on it", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, issues, _frame} = ListIssues.execute(%{}, frame)

        assert response_text(issues) =~ "the harness is holding a dead MCP client",
               """
               The refusal left an agent broken and nobody told.

               That is the same failure 3292 names, and it is the whole value of
               refusing: the point of not taking an action you must not take is
               to convert it into a decision for somebody who can. A refusal
               that ends there is worse than the action, because at least the
               action would have been noticed.

               issues:
               #{response_text(issues)}
               """

        {:ok, context}
      end
    end
  end
end
