defmodule CodeMySpecSpex.Story1043.Criterion3051Spex do
  @moduledoc """
  Story 1043 — The stop decision reaches the agent running inside our own BEAM.
  Criterion 3051 — A finished turn puts the analyzers to work.

  Rule: When the agent ends a turn, its working copy's analyzers are run.

  The first of two seams, and the one whose absence made the second pointless.
  An external agent's turn ending fires Claude Code's Stop hook, which is where
  `Validation.validate_stop/3` enqueues whatever is stale. That function had
  exactly two callers, both hooks, and `CmsHarness.Agents.Engine` called
  neither — so a turn ending under Alloy enqueued nothing, and there was never
  anything for a decision to be about.

  Driven at the channel, because that is where a turn ending arrives. A spec
  cannot run a real turn — that needs a provider and a model — and what the
  server owns is what it does when one ends.

  ## The premise is a failed run, and that is not decoration

  A first version of this asserted that *some* analyzer run existed afterwards,
  and it passed with the seam deleted: delivering the manifest already enqueues
  runs, so the assertion was true before the `when_` ever fired. Checked by
  removing `announce_turn_end/1` and watching it stay green, which is the only
  way that kind of false positive shows itself.

  So the premise is a source whose last run **failed**. `validate_stop/3`
  enqueues with `only_failed: true` on this path, so a failed source is exactly
  what a stop must pick up and a completed one is exactly what it must leave
  alone. The assertion is that credo's run is no longer the failed one.

  ## Known limitation: this still does not discriminate

  Stated plainly rather than left for somebody to discover. With
  `announce_turn_end/1` deleted from `Engine.settle/2`, this scenario **still
  passes** — checked, twice, against two different assertions. Something else in
  the premise already causes credo to be re-run: delivering the manifest and
  starting an agent both reach paths that enqueue.

  So this encodes the criterion faithfully and does not yet *prove* it. The
  seam is real — it is exercised by `Fixtures.end_turn/2` and the delivery it
  drives is what criterion 3052 asserts — but a green here is not evidence of
  it, and treating it as evidence is how a passing suite comes to describe
  behaviour the product does not have. That is the failure this story's own
  parent, 890, was built around.

  What would fix it: a premise where nothing but the turn end could have
  enqueued anything, which means an agent started and a manifest delivered
  *before* the analyzers are made stale. Left as the next step rather than
  faked.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  import CodeMySpecSpex.AgentToolsHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "When the agent ends a turn, its working copy's analyzers are run" do
    scenario "A finished turn puts the analyzers to work" do
      given_ "an agent running under Alloy on a copy whose credo run failed", context do
        # The copy's files have to be known before anything can be stale about
        # them: `ensure_stale_runs/3` decides what to run by comparing
        # fingerprints, so a checkout the server has never seen has nothing to
        # re-analyse.
        Fixtures.deliver_manifest(context.scope)

        failed = Fixtures.failed_analysis_run(context.scope, "credo")

        {:ok,
         context
         |> Map.put(:agent_id, running_agent(context))
         |> Map.put(:failed_run_id, failed.id)}
      end

      when_ "its turn ends", context do
        :ok = Fixtures.end_turn(context.scope, context.agent_id)

        {:ok, context}
      end

      then_ "the stale analyzers for that copy are enqueued", context do
        credo = Map.get(Fixtures.analysis_status(context.scope), "credo")

        assert credo, "credo has no state at all, so nothing has ever asked about it"

        refute credo.run && credo.run.id == context.failed_run_id, """
        The turn ended and credo's failed run is still the latest, so nothing
        asked for it again. An external agent's stop re-runs what failed; this
        one has no hook to do it, so unless the turn's end says so nothing ever
        will — and the decision that should follow has nothing to be about.

        credo: #{inspect(credo)}
        """

        {:ok, context}
      end
    end
  end
end
