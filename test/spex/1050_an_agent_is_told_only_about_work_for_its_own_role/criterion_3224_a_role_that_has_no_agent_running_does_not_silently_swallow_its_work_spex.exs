defmodule CodeMySpecSpex.Story1050.Criterion3224Spex do
  @moduledoc """
  Story 1050 — An agent is told only about work for its own role.
  Criterion 3224 — A role that has no agent running does not silently swallow
  its work.

  What routing does when the destination is empty, and the two wrong answers it
  has to avoid are opposites.

  Giving it to somebody else is the generous failure: QA work handed to the
  coding agent because QA is not running. That is the whole story reversed, and
  it arrives disguised as robustness.

  Dropping it is the tidy failure, and it is worse. Work that no role claims and
  nothing records is work that does not exist — the story sits ready for QA
  forever, no agent is waiting on it, and every page shows a project with
  nothing outstanding.

  So the answer is neither: it stays where it is, unclaimed and visible.
  `list_agent_work` is where that has to show, because it is what the main
  agent reads on its cadence and therefore the one place a human-free system
  can notice its own gap.
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
    scenario "A role that has no agent running does not silently swallow its work" do
      given_ "the project chain is past kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "a coding agent and no QA agent running", context do
        coding = Fixtures.running_agent(context.scope, role: "coding")
        context = context |> start_session() |> put_to_work()
        :ok = Fixtures.watch_graph(context.scope)

        refute "qa" in Enum.map(Fixtures.list_agents(context.scope), &to_string(&1.role)),
               "the premise is a role with nobody running, and QA is running"

        {:ok,
         context
         |> Map.put(:coding, coding.id)
         |> Map.put(:before, heard_count(context, coding.id))}
      end

      given_ "QA work that is ready", context do
        story = Fixtures.released_story(context.scope, "Refunds reach the ledger")
        Fixtures.record_deploy(context.scope, story.id, "dev")

        {:ok, Map.put(context, :story, story)}
      end

      when_ "the work is routed", context do
        :ok = Fixtures.settle_graph(context.scope)

        {:ok, context}
      end

      then_ "it is not delivered to the coding agent instead", context do
        refute_told_anything(
          context,
          context.coding,
          context.before,
          """
          QA work was handed to the coding agent because QA was not running.

          This is the whole story reversed, and it arrives disguised as
          robustness — "somebody should see it" reads as care and produces an
          agent acting outside its role on work it was not meant to have.
          """
        )

        {:ok, context}
      end

      then_ "and it remains visibly unclaimed rather than disappearing", context do
        {:reply, reply, _frame} = CheckIn.execute(%{}, frame(context))
        report = response_text(reply)

        assert report =~ ~r/(qa|unclaimed|waiting|no agent|outstanding)/i,
               """
               Work no role claimed is not visible anywhere.

               Dropping it is the tidy failure and the worse one: the story
               sits ready for QA forever, no agent is waiting on it, and every
               page shows a project with nothing outstanding.

               `check_in` is where it has to show, because that is what the
               main agent reads on its cadence — the one place a system with no
               human in it can notice its own gap.

               #{report}
               """

        {:ok, context}
      end
    end
  end
end
