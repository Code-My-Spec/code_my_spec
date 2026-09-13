defmodule CodeMySpecSpex.Story1048.Criterion3192Spex do
  @moduledoc """
  Story 1048 — Work appearing on the graph reaches the agent who can do it.
  Criterion 3192 — A story ready to test wakes the QA agent.

  3188 for the other role, and it is not a copy of it. QA work has a
  precondition coding work does not: the story's code has to be on the checkout
  the application runs from, which is story 1046's whole subject. A wake that
  fires on "ready for QA" without that is an agent sent to test a stale app,
  and what it reports is a defect in code nobody wrote.

  So the premise here includes the deploy, and it is stated rather than assumed
  — without it this scenario would pass against an implementation that wakes QA
  the moment a story is marked, which is the failure mode with the worst
  output: not a missed wake but a false bug report.

  This is also the criterion that keeps the role filter honest in the other
  direction. 1047's 3179 asserts QA work does not wake coding; nothing yet says
  QA work wakes QA.
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

  spex "Work appearing inside an agent's role and copy reaches that agent" do
    scenario "A story ready to test wakes the QA agent" do
      given_ "the project chain is past kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "a QA agent running and idle on its working copy", context do
        qa = Fixtures.running_agent(context.scope, role: "qa")
        context = context |> start_session() |> put_to_work()
        :ok = Fixtures.watch_graph(context.scope)

        {:ok,
         context
         |> Map.put(:qa, qa.id)
         |> Map.put(:before, heard_count(context, qa.id))}
      end

      given_ "a story whose code is on the running dev copy", context do
        story = Fixtures.released_story(context.scope, "Refunds reach the ledger")

        {:ok, Map.put(context, :story, story)}
      end

      when_ "that story becomes ready for QA", context do
        Fixtures.record_deploy(context.scope, context.story.id, "dev")
        :ok = Fixtures.settle_graph(context.scope)

        {:ok, context}
      end

      then_ "the QA agent receives a message naming that story", context do
        said = said_since(context, context.qa, context.before)

        refute said == [],
               """
               A story became testable and the agent that tests it was told
               nothing.

               1047's 3179 says QA work must not wake the coding agent.
               Nothing else says it wakes QA — so an implementation that wakes
               nobody satisfies that criterion perfectly.
               """

        assert Enum.any?(
                 said,
                 &(&1 =~ ~r/(get_next_requirement|qa|#{Regex.escape(context.story.title)})/i)
               ),
               """
               The QA agent was woken without being told what for.

               #{Enum.join(said, "\n---\n")}
               """

        {:ok, Map.put(context, :said, said)}
      end

      then_ "and it begins a turn without a person routing it", context do
        refute Enum.any?(context.said, &(&1 =~ ~r/(ask|waiting for|approval|confirm)/i)),
               """
               The wake asks somebody before QA may act on it, which puts a
               person back in the loop this story exists to remove.

               #{Enum.join(context.said, "\n---\n")}
               """

        {:ok, context}
      end
    end
  end
end
