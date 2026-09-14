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
  alias CodeMySpecSpex.FullSatisfactionFixtures
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
      # No kickoff and no separately synced component. `apply_without_qa_story/1`
      # in the `when_` builds the whole project itself — setup steps, strategy,
      # architecture, its own component subgraph and its own story — and a
      # component this scenario synced beforehand is not in that subgraph, so it
      # lands as an orphan and reopens `architecture_designed` for `:main`.
      # Measured: the graph after the `when_` held exactly
      # `[main: "architecture_designed"]` and QA's queue was empty, so the
      # criterion failed on scenery rather than on routing.
      given_ "a QA agent running and idle on its working copy", context do
        qa = Fixtures.running_agent(context.scope, role: "qa")
        context = context |> start_session() |> put_to_work()
        :ok = Fixtures.watch_graph(context.scope)

        {:ok,
         context
         |> Map.put(:qa, qa.id)
         |> Map.put(:before, heard_count(context, qa.id))}
      end

      when_ "a story reaches the point where it is ready to test", context do
        # The chain completing is what puts work in QA's lane, and
        # `apply_without_qa_story/1` is that state by name: "the chain prepared
        # so a `qa_complete` task can be STARTED". Its last step stamps a fresh
        # green analysis run, which satisfies `bdd_specs_passing` and so makes
        # `qa_complete` actionable.
        #
        # It used to release a story and record a deploy to dev. Neither gates
        # `qa_complete`: its prerequisite is `code_on_running_copy`, and
        # `Promotion.running_copy_check/2` answers {true, "No running copy
        # designated"} on a project with no designated main copy — so it was
        # already satisfied and the deploy moved nothing. QA's lane stayed
        # empty, and "the agent that tests it was told nothing" was the correct
        # answer to a scenario that had made nothing testable.
        context = FullSatisfactionFixtures.apply_without_qa_story(context)
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
                 &(&1 =~ ~r/(get_next_requirement|qa|qa_complete)/i)
               ),
               """
               The QA agent was woken without being told what for.

               #{Enum.join(said, "\n---\n")}
               """

        {:ok, Map.put(context, :said, said)}
      end

      then_ "and it begins a turn without a person routing it", context do
        # `Validation.Menu` ends every message it renders with three standing
        # offers, none of them conditional (story 896), and one of them names
        # `ask_user_question` while `tap_out_offer/1` ends "once a human
        # approves". So the whole message matches this pattern on every
        # implementation there will ever be, including one that routes nobody
        # — the assertion could not have passed, and was reading boilerplate
        # that is correct and by design.
        #
        # The routing lives in what precedes them. `Menu.offers/1` always
        # opens with `answer_offer/1`, whose three clauses are the boundary —
        # every one of them mentions a question having been asked or being
        # "waiting on the user", so the offer block cannot be matched on
        # without matching this pattern. If Menu's offers change, this changes
        # with them; there is no way to ask about the work half without
        # knowing where it ends.
        offer_block = ~r/\n\n(If a question you asked|\d+ questions? (is|are) open and waiting)/

        work =
          Enum.map(
            context.said,
            &(&1 |> String.split(offer_block, parts: 2) |> hd())
          )

        refute Enum.any?(work, &(&1 =~ ~r/(ask|waiting for|approval|confirm)/i)),
               """
               The wake asks somebody before QA may act on it, which puts a
               person back in the loop this story exists to remove.

               #{Enum.join(work, "\n---\n")}
               """

        {:ok, context}
      end
    end
  end
end
