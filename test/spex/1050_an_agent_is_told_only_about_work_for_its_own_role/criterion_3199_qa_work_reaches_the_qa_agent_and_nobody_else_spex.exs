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

  ## The premise, borrowed rather than reinvented

  `qa_complete`'s real gate is `bdd_specs_passing`, not a release-and-deploy —
  1048's criterion 3192 already found that the hard way: releasing a story and
  recording a deploy to dev satisfies nothing, because `code_on_running_copy`
  was already trivially true with no main copy designated. So this uses the
  same `FullSatisfactionFixtures.apply_without_qa_story/1` chain 3192 validated,
  rather than reintroducing the deploy-based premise that never produced
  actionable QA work in the first place.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Work is told to the role that can act on it, and to no other" do
    scenario "QA work reaches the QA agent and nobody else" do
      given_ "a project whose only remaining work is QA on one story", context do
        # Settled here rather than in the `when_`, and that is the whole point
        # of the split. `apply_without_qa_story/1` builds an entire project,
        # and building a project is coding-role work — so a coding agent that
        # has been running throughout hears about its own genuine work, and a
        # before/after comparison across the `when_` cannot tell that from a
        # role leak. This criterion failed on a correctly routed wake for
        # exactly that reason. `apply_up_to_analysis/1` is the same chain minus
        # the QA-readiness transition (specs enforcement + a green analysis
        # run) — see its doc for why the two can't be split further — so the
        # only transition left for the `when_` is the one this criterion is
        # about.
        context = FullSatisfactionFixtures.apply_up_to_analysis(context)

        # Asserted, not assumed — a red premise here is honest where a red
        # assertion three steps later is not. This is the check that caught
        # the leak in the first place: before `apply_up_to_analysis/1` was
        # fixed to stop short of `apply_specs_enforced/1`, `qa_complete` was
        # already actionable at this point.
        refute "qa_complete" in Fixtures.actionable_names(context.scope, :qa),
               """
               `qa_complete` was already actionable before the QA-readiness
               transition ran, so there is nothing left for the `when_` to
               unblock and the assertions below would be measuring a stale
               premise rather than a routed wake.

               QA-actionable now: #{inspect(Fixtures.actionable_names(context.scope, :qa))}
               """

        # Everything coding owns except the one thing the `when_` is about.
        #
        # `apply_up_to_analysis/1` withholds the analysis run entirely, so
        # coding is left holding both `tests_passing` and `bdd_specs_passing`.
        # The transition in the `when_` satisfies the second and not the first,
        # so coding would still have real work afterwards — and a role that has
        # work is woken correctly, which is indistinguishable here from the leak
        # this criterion exists to catch. It is the same hazard the comment
        # above describes, one step further in.
        #
        # Every source but `spex`, so `tests_passing` is satisfied now and
        # `bdd_specs_passing` is left for the transition. Coding then holds
        # exactly one requirement, the `when_` clears it, and afterwards coding's
        # queue is empty — so any message it receives is a leak rather than its
        # own work arriving.
        Fixtures.fresh_analysis_runs(context.scope, ["compiler", "credo", "exunit"])

        assert Fixtures.actionable_names(context.scope, :coding) == ["bdd_specs_passing"],
               """
               Coding should hold exactly the one requirement the `when_` is
               about to satisfy, and nothing else.

               More than that and coding still has work after the transition, so
               it is woken correctly and this criterion cannot tell that from a
               role leak. Less than that and the transition clears nothing for
               coding, which means the premise never set the scenario up.

               Coding-actionable now: #{inspect(Fixtures.actionable_names(context.scope, :coding))}
               """

        {:ok, context}
      end

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
        # One step, not a whole project. `apply_qa_readiness_transition/1` is
        # the QA-readiness transition itself — specs enforcement plus a fresh
        # green run, together, since neither half alone leaves `qa_complete`
        # inactionable in between (see its doc) — and it is the only thing
        # that changes here.
        context = FullSatisfactionFixtures.apply_qa_readiness_transition(context)
        after_runs = Fixtures.actionable_names(context.scope, :qa)

        :ok = Fixtures.settle_graph(context.scope)
        after_settle = Fixtures.actionable_names(context.scope, :qa)

        {:ok,
         context
         |> Map.put(:after_runs, after_runs)
         |> Map.put(:after_settle, after_settle)}
      end

      then_ "the QA agent is told about it", context do
        # "The QA agent was told nothing" has two causes that read identically
        # here: either the wake was not routed to QA — what this criterion is
        # about — or the graph held no QA work at this moment, in which case
        # telling nobody was correct and the premise never arrived. The
        # `given_`'s asserted premise and `after_runs`/`after_settle` below
        # rule the second one out; a failure past those two is routing.
        actionable = Fixtures.actionable_names(context.scope, :qa)
        unsatisfied = Fixtures.unsatisfied_reasons(context.scope, context.story.id)

        assert heard_count(context, context.qa) > context.qa_before,
               """
               The role that can act on this work was told nothing.

               Stated as a pair on purpose: "the coding agent is not told" is
               satisfied by telling nobody, so without this half the criterion
               passes against a system that routes nothing anywhere.

               QA-actionable requirements at this moment: #{inspect(actionable)}
               This story's unsatisfied requirements at this moment: #{inspect(unsatisfied)}

               QA heard #{heard_count(context, context.qa)} (was #{context.qa_before}).
               Coding heard #{heard_count(context, context.coding)} (was #{context.coding_before}).

               Agents the wake would consider: #{inspect(Enum.map(Fixtures.running_agents(context.scope), &{&1.role, &1.continuous, &1.status, &1.working_copy_id}))}
               This scope's working copy: #{inspect(context.scope.active_working_copy_id)}

               QA-actionable straight after the readiness transition: #{inspect(context.after_runs)}
               QA-actionable after settle_graph:                      #{inspect(context.after_settle)}

               Those two counts are the fork. Both unchanged means nobody was
               woken and the routing never ran. Coding up while QA is flat means
               it ran and chose wrong, which is this criterion's actual subject
               and the more serious of the two.
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
