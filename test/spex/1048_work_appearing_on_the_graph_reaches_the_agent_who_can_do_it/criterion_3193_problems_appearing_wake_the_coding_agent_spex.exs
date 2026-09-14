defmodule CodeMySpecSpex.Story1048.Criterion3193Spex do
  @moduledoc """
  Story 1048 — Work appearing on the graph reaches the agent who can do it.
  Criterion 3193 — Problems appearing wake the coding agent.

  The case where "work appearing on the graph" is not a requirement appearing
  on the graph. A failing analyzer produces problems, problems are coding work,
  and the graph does not carry them as requirements — so an implementation that
  wakes on requirement count alone satisfies every other criterion here and
  leaves a broken build sitting under an idle agent.

  It is the worst silence of the set because of how it looks. A copy with a red
  build and an agent that correctly reads its empty queue and stops is
  indistinguishable, from every page, from a copy that has finished its work.

  1047's 3183 is the same claim from the "what the nudge says" side: there the
  wake exists and must name the problems, here the wake must exist at all.
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

  spex "Work appearing inside an agent's role and copy reaches that agent" do
    scenario "Problems appearing wake the coding agent" do
      given_ "the project chain is past kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ "a coding agent running and idle on its working copy", context do
        coding = Fixtures.running_agent(context.scope, role: "coding")
        context = context |> start_session() |> put_to_work()
        :ok = Fixtures.watch_graph(context.scope)

        {:ok,
         context
         |> Map.put(:coding, coding.id)
         |> Map.put(:before, heard_count(context, coding.id))}
      end

      when_ "problems appear on stories assigned to that working copy", context do
        {:ok, _problems} =
          Fixtures.record_problem(context.scope, "credo", %{
            message: "nesting too deep in the ledger writer"
          })

        :ok = Fixtures.settle_graph(context.scope)

        {:ok, context}
      end

      then_ "the coding agent receives a message naming those problems", context do
        said = said_since(context, context.coding, context.before)

        refute said == [],
               """
               Problems appeared on this agent's own checkout and it was told
               nothing.

               Problems are coding work and the graph does not carry them as
               requirements, so an implementation that wakes on requirement
               count satisfies every other criterion on this story and leaves a
               red build under an idle agent.

               And it looks fine: a copy with problems and an agent that
               correctly read its empty queue is indistinguishable, from every
               page, from a copy that has finished.
               """

        assert Enum.any?(said, &(&1 =~ ~r/(problem|credo|nesting too deep|fix)/i)),
               """
               The agent was woken and the wake does not say the work is the
               problems — so it will read the graph, find no requirement, and
               stop, having been woken for something it cannot find.

               #{Enum.join(said, "\n---\n")}
               """

        {:ok, Map.put(context, :said, said)}
      end

      then_ "and it begins a turn without a person routing it", context do
        # The directive line, not the whole message. Every menu ends with the
        # same three standing offers and the tap-out, and two of them say
        # `ask_user_question` and "once a human approves" — always, to every
        # agent, as things it *may* do. Matching those as gatekeeping makes the
        # criterion unsatisfiable by any menu at all, which is a claim about
        # the boilerplate rather than about this wake.
        directives = Enum.map(context.said, &(&1 |> String.split("\n\n") |> Enum.at(1, "")))

        refute Enum.any?(directives, &(&1 =~ ~r/(waiting for|approval|sign.?off|permission)/i)),
               """
               The wake makes the agent wait on somebody before it may fix its
               own checkout's build.

               #{Enum.join(directives, "\n---\n")}
               """

        {:ok, context}
      end
    end
  end
end
