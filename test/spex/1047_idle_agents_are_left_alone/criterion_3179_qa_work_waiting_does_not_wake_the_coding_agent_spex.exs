defmodule CodeMySpecSpex.Story1047.Criterion3179Spex do
  @moduledoc """
  Story 1047 — Idle agents are left alone.
  Criterion 3179 — QA work waiting does not wake the coding agent.

  The queue an agent is woken for is its own role's. Story 538's R10 already
  says so for the stop decision; this says it for the doorbell, and the two
  fail independently — a wake that broadcasts to everyone on the copy is the
  obvious implementation of 3178 and passes it completely.

  What it costs is not noise. A coding agent woken by QA work spends a real
  turn on somebody's subscription reading the graph, finding nothing it can do,
  and stopping — and it does that every time QA work appears, which on a busy
  copy is constantly.

  Both agents are on one working copy on purpose. Wrong-role wakes are only
  observable where the two agents share everything except the role, which is
  also where a broadcast implementation looks most correct.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An agent is woken for its own role's queue and no other" do
    scenario "QA work waiting does not wake the coding agent" do
      given_ "the graph holds QA work and no coding work", context do
        # Everything satisfied except the story's own QA, which is what
        # `apply_without_qa_story/1` exists for — "the chain prepared so a
        # `qa_complete` task can be STARTED".
        #
        # The criterion was reaching for that state with a released story and a
        # deploy record, and `qa_complete` sits behind the whole chain (three
        # amigos, specs green on a fresh run, code on the running copy), so it
        # never became actionable. Both lanes read zero and the scenario proved
        # nothing about either role: it could not say the coding agent was left
        # alone because its role's queue was empty, only that nothing at all
        # was going on.
        {:ok, CodeMySpecSpex.FullSatisfactionFixtures.apply_without_qa_story(context)}
      end

      given_ "a coding agent and a QA agent both running on one copy", context do
        coding = Fixtures.running_agent(context.scope, role: "coding")
        qa = Fixtures.running_agent(context.scope, role: "qa")

        {:ok,
         context
         |> Map.put(:coding, coding.id)
         |> Map.put(:qa, qa.id)
         |> Map.put(:coding_before, heard_count(context, coding.id))
         |> Map.put(:qa_before, heard_count(context, qa.id))}
      end

      when_ "the copy is switched on and the graph is evaluated", context do
        {:ok, put_to_work(context)}
      end

      then_ "the QA agent is nudged", context do
        assert heard_count(context, context.qa) > context.qa_before,
               """
               The role whose work is waiting heard nothing, so this scenario
               cannot say anything about the role whose work is not.

               Without this the criterion passes on a system that wakes nobody
               ever, which is the failure 3178 exists to rule out.
               """

        {:ok, context}
      end

      then_ "and the coding agent is sent nothing", context do
        refute_told_anything(
          context,
          context.coding,
          context.coding_before,
          """
          The coding agent was woken by work only QA can do.

          It will spend a real turn reading the graph, finding nothing it can
          do, and stopping — every time QA work appears, which on a busy copy
          is constantly. That is the spend this story exists to stop.
          """
        )

        {:ok, context}
      end
    end
  end
end
