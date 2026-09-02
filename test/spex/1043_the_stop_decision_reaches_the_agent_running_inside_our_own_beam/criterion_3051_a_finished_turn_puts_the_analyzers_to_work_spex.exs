defmodule CodeMySpecSpex.Story1043.Criterion3051Spex do
  @moduledoc """
  Story 1043 — The stop decision reaches the agent running inside our own BEAM.
  Criterion 3051 — A finished turn puts the analyzers to work.

  Rule: When the agent ends a turn, its working copy's analyzers are run.

  The first of the two seams, and the one whose absence made the second
  pointless. An external agent's turn ending fires Claude Code's Stop hook,
  which is where `Validation.validate_stop/3` enqueues whatever is stale. That
  function had exactly two callers, both hooks, and `CmsHarness.Agents.Engine`
  called neither — so a turn ending under Alloy enqueued nothing, and there was
  never anything to deliver.

  Driven at the channel, because that is where a turn ending arrives. A spec
  cannot run a real turn — that needs a provider and a model — and what the
  server owns is what it does when one ends.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  import CodeMySpecSpex.AgentToolsHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "When the agent ends a turn, its working copy's analyzers are run" do
    scenario "A finished turn puts the analyzers to work" do
      given_ "an agent running under Alloy that has edited code", context do
        {:ok, Map.put(context, :agent_id, running_agent(context))}
      end

      when_ "its turn ends", context do
        :ok = Fixtures.end_turn(context.scope, context.agent_id)

        {:ok, context}
      end

      then_ "the stale analyzers for that copy are enqueued", context do
        # Asked of the run ledger through the surface that reports it, rather
        # than by querying: what "enqueued" means is a run the server will
        # answer for, and the ledger is where that lives.
        assert Fixtures.analysis_runs_in_flight?(context.scope), """
        The turn ended and nothing was asked of the analyzers. An external
        agent's stop enqueues whatever is stale; this one has no hook to do it,
        so unless the turn's end says so nothing ever will — and the decision
        that should follow has nothing to be about.
        """

        {:ok, context}
      end
    end
  end
end
