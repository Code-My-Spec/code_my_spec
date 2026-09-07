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

  ## What this proves, and what it does not

  It proves the **server** half. Neutering `StopDecision.deliver/2` in
  `Agents.record_turn_event/3` turns this red, so the chain from a turn-ended
  event through the decision to the analyzers being asked for is genuinely
  under test.

  It does **not** cover the harness half — `Engine.settle/2` emitting the event
  in the first place. `Fixtures.end_turn/2` drives the channel directly, which
  is the only thing a spec can do: running a real turn needs a provider and a
  model. Deleting `announce_turn_end/1` leaves this scenario green, and that is
  correct rather than a gap in the assertion. It cost three attempts to see —
  the first two "it does not discriminate" readings were me removing the half
  this scenario was never touching.

  So the harness half is covered by the QA session on a real agent, not here.
  Worth knowing before trusting a green: it says the server does the right
  thing when told, and says nothing about whether it gets told.

  ## Order in the premise is load-bearing

  Both delivering the manifest and starting an agent reach paths that enqueue,
  so the failed run is created **last** — the one piece of state nothing before
  the `when_` has reacted to. Written the other way round, the scenario passes
  on runs an earlier step caused.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  alias CodeMySpecSpex.Fixtures

  import CodeMySpecSpex.AgentToolsHelpers

  # See criterion 3059's note: `end_turn` re-triggers a full, real analyzer
  # pass, including a real recursive `mix spex` that has nothing to do with
  # this scenario. Credo itself is left to the cassette's own recorded
  # command — reconciliation still produces a fresh completed run either
  # way, which is the thing this criterion actually checks.
  @end_turn_opts [
    compile_output_file: Path.expand("test/fixtures/validation/pipeline_clean_run/compile.jsonl"),
    spex_output_file: Path.expand("test/fixtures/validation/spex_green.jsonl")
  ]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "When the agent ends a turn, its working copy's analyzers are run" do
    scenario "A finished turn puts the analyzers to work" do
      given_ "an agent running under Alloy on a copy the server knows", context do
        # Order matters, and getting it wrong is what made two earlier versions
        # of this scenario pass with the seam deleted. Both the manifest and
        # starting an agent reach paths that enqueue, so anything they cause
        # must happen *before* the state this scenario is about exists.
        Fixtures.deliver_manifest(context.scope)

        {:ok, Map.put(context, :agent_id, running_agent(context))}
      end

      given_ "and credo's last run failed", context do
        # Last, so it is the one thing nothing before the `when_` has reacted
        # to. `validate_stop/3` enqueues with `only_failed: true` on this path,
        # so a failed source is exactly what a stop must pick up.
        failed = Fixtures.failed_analysis_run(context.scope, "credo")

        {:ok, Map.put(context, :failed_run_id, failed.id)}
      end

      when_ "its turn ends", context do
        :ok =
          use_cmd_cassette "clean", record: :none do
            Fixtures.end_turn(context.scope, context.agent_id, @end_turn_opts)
          end

        {:ok, context}
      end

      then_ "the stale analyzers for that copy are enqueued", context do
        credo = Map.get(Fixtures.analysis_status(context.scope), "credo")

        assert credo, "credo has no state at all, so nothing has ever asked about it"

        # Both halves asserted separately, and deliberately. Written as
        # `refute credo.run && credo.run.id == ...` this passed whenever
        # `credo.run` was nil — `refute nil` succeeds — so a source with no run
        # at all read as a source that had been re-run. That is a third way this
        # scenario found to be green without proving anything.
        assert credo.run, """
        credo has no run at all after the turn ended, so nothing was enqueued
        and nothing recorded. The state map says: #{inspect(credo)}
        """

        refute credo.run.id == context.failed_run_id, """
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
