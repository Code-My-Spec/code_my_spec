defmodule CodeMySpecSpex.Story1050.Criterion3199Spex do
  @moduledoc """
  Story 1050 — An agent is told only about work for its own role.
  Criterion 3199 — QA work reaches the QA agent and nobody else.

  The base case of the whole story, stated as a pair so it cannot be satisfied
  by either half alone. Telling the QA agent is satisfied by telling everybody;
  not telling the coding agent is satisfied by telling nobody. Only the
  conjunction says "routed".

  The cost of getting it wrong is attention, which is the story's own word. A
  coding agent told about QA work reads it — that is what a model does with
  text in its context — and then either acts on it, which is another agent's
  job done twice, or reasons about why it should not, which is a turn spent
  deciding to do nothing.

  Both agents on one working copy, because that is where a role filter is
  actually load-bearing. Split across copies, a checkout filter alone would
  pass this and the role filter would never be exercised.
  """

  use CodeMySpecSpex.Case

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

  spex "Work is told to the role that can act on it, and to no other" do
    scenario "QA work reaches the QA agent and nobody else" do
      given_ "the project chain is past kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "a coding agent and a QA agent running on one working copy", context do
        coding = Fixtures.running_agent(context.scope, role: "coding")
        qa = Fixtures.running_agent(context.scope, role: "qa")
        context = context |> start_session() |> put_to_work()
        :ok = Fixtures.watch_graph(context.scope)

        {:ok,
         context
         |> Map.put(:coding, coding.id)
         |> Map.put(:qa, qa.id)
         |> Map.put(:coding_before, heard_count(context, coding.id))
         |> Map.put(:qa_before, heard_count(context, qa.id))}
      end

      when_ "a story becomes ready for QA", context do
        story = Fixtures.released_story(context.scope, "Refunds reach the ledger")
        Fixtures.record_deploy(context.scope, story.id, "dev")
        :ok = Fixtures.settle_graph(context.scope)

        {:ok, Map.put(context, :story, story)}
      end

      then_ "the QA agent is told about it", context do
        assert heard_count(context, context.qa) > context.qa_before,
               """
               The role that can act on this work was told nothing.

               Stated as a pair on purpose: "the coding agent is not told" is
               satisfied by telling nobody, so without this half the criterion
               passes against a system that routes nothing anywhere.
               """

        {:ok, context}
      end

      then_ "and the coding agent is not told about it", context do
        refute_told_anything(
          context,
          context.coding,
          context.coding_before,
          """
          The coding agent was told about QA work.

          Attention is the cost, which is this story's own word for it. A model
          reads what is in its context — so it either acts on this, which is
          another agent's job done twice, or reasons about why it should not,
          which is a turn spent deciding to do nothing.

          Both agents share a checkout here, which is where a role filter is
          actually load-bearing: split across copies, a checkout filter alone
          would pass this.
          """
        )

        {:ok, context}
      end
    end
  end
end
