defmodule CodeMySpecSpex.Story1048.Criterion3194Spex do
  @moduledoc """
  Story 1048 — Work appearing on the graph reaches the agent who can do it.
  Criterion 3194 — An unreachable agent does not make the graph retry.

  The wake is a publish, and the three Thens are three ways of saying the same
  design decision: the graph's job ends when it has said what changed.

  `CmsHarness.Agents`'s reporter already carries the reasoning for its own
  direction — "fire and forget: an agent's work does not stop because nobody is
  watching, and a reporting failure must not become a turn failure." This is
  that rule pointed the other way, and it matters more here, because the thing
  that would be held up is the recompute every other agent on the project is
  waiting on.

  An agent's machine being down is ordinary — a laptop closes, a container
  restarts, a harness is upgraded. If that can make the graph retry, wait, or
  block, then one closed laptop degrades the whole project, and it does so
  silently.

  What replaces delivery guarantees is the rejoin: an agent that comes back
  asks what it should be doing. That is why losing a wake is survivable and
  holding the graph is not.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers, only: [machine_out_of_reach: 0]
  import CodeMySpecSpex.GraphReadHelpers, only: [warm_graph: 1]
  import CodeMySpecSpex.IdleAgentHelpers
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The graph's job ends when it has said what changed" do
    scenario "An unreachable agent does not make the graph retry" do
      given_ "the project chain is past kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "a coding agent registered but not reachable", context do
        coding = Fixtures.running_agent(context.scope, role: "coding")
        context = context |> start_session() |> put_to_work() |> warm_graph()

        # Its machine goes. Ordinary: a laptop closes, a container restarts, a
        # harness is upgraded. The row stays, which is the point — the graph
        # still has somebody to address.
        machine_out_of_reach()

        :ok = Fixtures.watch_graph(context.scope)

        {:ok,
         context
         |> Map.put(:coding, coding.id)
         |> Map.put(:before, heard_count(context, coding.id))}
      end

      when_ "work appears inside its role and working copy", context do
        story = Fixtures.authored_story(context.scope, "Refunds reach the ledger")
        :ok = Fixtures.mark_story_ready(context.scope, story)
        :ok = Fixtures.settle_graph(context.scope)

        {:ok, Map.put(context, :announcements, drain_announcements(context))}
      end

      then_ "the wake message is published once", context do
        assert context.announcements == 1,
               """
               The graph announced #{context.announcements} time(s) for one
               change against an unreachable agent.

               The publish does not depend on anybody being there to hear it.
               An announcement that is skipped because the audience is down,
               or repeated because it was, both make the graph's behaviour a
               function of somebody's laptop.
               """

        {:ok, context}
      end

      then_ "and nothing retries it", context do
        again = drain_announcements(context)

        assert again == 0,
               """
               #{again} further announcement(s) arrived for the same change.

               A retry loop against an agent that is simply off means one
               closed laptop produces traffic for as long as it stays closed —
               and the recompute every other agent is waiting on is behind it.
               """

        {:ok, context}
      end

      then_ "and nothing waits for an acknowledgement", context do
        assert Fixtures.settle_graph(context.scope) == :ok,
               """
               The graph could not settle again, so it is still holding
               something from the last change.

               `CmsHarness.Agents` already carries this rule in the other
               direction: a reporting failure must not become a turn failure.
               Here the cost is larger — what would be held up is the recompute
               the whole project reads from.

               What makes losing a wake survivable is the rejoin: an agent that
               comes back asks what it should be doing.
               """

        {:ok, context}
      end
    end
  end

  defp drain_announcements(context, seen \\ 0) do
    project_id = context.scope.active_project_id

    receive do
      {:graph_updated, ^project_id} -> drain_announcements(context, seen + 1)
    after
      500 -> seen
    end
  end
end
