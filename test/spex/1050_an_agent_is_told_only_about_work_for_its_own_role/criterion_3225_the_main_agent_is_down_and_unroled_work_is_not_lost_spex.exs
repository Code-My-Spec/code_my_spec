defmodule CodeMySpecSpex.Story1050.Criterion3225Spex do
  @moduledoc """
  Story 1050 — An agent is told only about work for its own role.
  Criterion 3225 — The main agent is down and unroled work is not lost.

  3224 with the last fallback removed. There the role was empty and the main
  agent was still there to be the answer; here the answer itself is gone, and
  the temptation to hand the work to whoever is left is at its strongest —
  there is literally nobody else.

  The main agent is also the most likely of the three to be down. It runs
  continuously, it is restarted when the project's own conversation is, and
  1047's 3186 argues it should be left alone when idle. So "main is not running"
  is not an edge case; it is a state this project is in regularly.

  Devops work is the worst thing to reroute during it. A working-copy agent
  handed infrastructure work acts on it from inside one checkout, and what it
  changes is the project's servers.

  "Still waiting when it returns" is what separates a queue from a broadcast.
  The work has to survive the outage on its own, not be re-derived by whatever
  happens to recompute next.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CodeMySpec.McpServers.MainAgent.Tools.CheckIn
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Work whose role has nobody running stays unclaimed rather than moving or vanishing" do
    scenario "The main agent is down and unroled work is not lost" do
      given_ "the project chain is past kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ "a coding agent, no devops role, and no main agent running", context do
        coding = Fixtures.running_agent(context.scope, role: "coding")
        context = context |> start_session() |> put_to_work()
        :ok = Fixtures.watch_graph(context.scope)

        roles = Enum.map(Fixtures.list_agents(context.scope), &to_string(&1.role))

        refute "main" in roles,
               "the premise is a project whose main agent is down, and one is running"

        refute "devops" in roles, "the premise is work whose role does not exist"

        {:ok,
         context
         |> Map.put(:coding, coding.id)
         |> Map.put(:before, heard_count(context, coding.id))}
      end

      when_ "devops work appears and is routed", context do
        :ok = Fixtures.enable_devops(context.scope)
        :ok = Fixtures.settle_graph(context.scope)

        {:ok, context}
      end

      then_ "it is not delivered to a working-copy agent instead", context do
        refute_told_anything(
          context,
          context.coding,
          context.before,
          """
          Infrastructure work was handed to a working-copy agent because the
          main agent was down.

          This is where the temptation is strongest — there is literally nobody
          else — and where it costs most: an agent inside one checkout acting
          on devops work changes the project's servers.

          The main agent being down is not an edge case. It runs continuously,
          it restarts with the project's conversation, and 1047's 3186 argues
          it should be left alone when idle.
          """
        )

        {:ok, context}
      end

      then_ "and it is still waiting for the main agent when it returns", context do
        main = Fixtures.running_agent(context.scope, role: "main")
        :ok = Fixtures.settle_graph(context.scope)

        {:reply, reply, _frame} = CheckIn.execute(%{}, frame(context))
        report = response_text(reply)

        assert report =~ ~r/(devops|infrastructure|server|environment|outstanding|waiting)/i,
               """
               The main agent came back and the work that was waiting for it is
               gone.

               Surviving the outage on its own is what separates a queue from a
               broadcast. Work that has to be re-derived by whatever happens to
               recompute next is work that depends on something else changing
               to be found again — and if nothing changes, it never is.

               main: #{main.id}

               #{report}
               """

        {:ok, context}
      end
    end
  end
end
