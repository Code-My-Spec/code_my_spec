defmodule CodeMySpecSpex.Story1047.Criterion3183Spex do
  @moduledoc """
  Story 1047 — Idle agents are left alone.
  Criterion 3183 — Problems on the agent's own work are named as the work.

  A problem on a story assigned to this copy *is* coding work, and the graph
  does not carry it as a requirement — so an agent with no open task and a
  broken build reads its queue as empty and stops. The build stays broken and
  the agent is correct at every step.

  This is the one case where "nothing in the queue" and "nothing to do" come
  apart, which is why it is a criterion rather than a consequence of 3178. An
  implementation that counts requirements satisfies every other criterion on
  this story and leaves this one failing silently — the worst shape, because a
  copy with problems on it looks exactly like a copy that is finished.

  Scoped to the agent's own working copy, because problems elsewhere are
  somebody else's and waking on them is 3184's failure by another route.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Work an agent can do is named as work, whether or not the graph carries it" do
    scenario "Problems on the agent's own work are named as the work" do
      given_ "the project chain is past kickoff, so role work is the frontier", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ "a coding agent with no open task", context do
        coding = Fixtures.running_agent(context.scope, role: "coding")
        context = put_to_work(context)

        {:ok,
         context
         |> Map.put(:coding, coding.id)
         |> Map.put(:before, heard_count(context, coding.id))}
      end

      given_ "problems on stories assigned to its working copy", context do
        {:ok, _problems} =
          Fixtures.record_problem(context.scope, "credo", %{
            message: "nesting too deep in the ledger writer"
          })

        {:ok, context}
      end

      when_ "the agent is nudged", context do
        {:ok, put_to_work(context)}
      end

      then_ "the nudge names fixing those problems", context do
        said = latest(context, context.coding)

        assert said,
               """
               An agent with problems on its own checkout was told nothing.

               Its requirement queue is empty and its build is broken, and it
               is correct at every step: it reads the queue, finds nothing, and
               stops. The problems stay, and a copy in this state looks exactly
               like one that is finished.
               """

        assert said =~ ~r/(problem|fix|credo|nesting too deep)/i,
               """
               The agent was woken and the wake does not say the work is the
               problems, so it will read the graph, find no requirement, and
               stop — having been woken for something it cannot find.

               got: #{said}
               """

        {:ok, context}
      end
    end
  end
end
