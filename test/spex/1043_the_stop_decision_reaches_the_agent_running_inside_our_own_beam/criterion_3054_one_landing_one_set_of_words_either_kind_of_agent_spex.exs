defmodule CodeMySpecSpex.Story1043.Criterion3054Spex do
  @moduledoc """
  Story 1043 — The stop decision reaches the agent running inside our own BEAM.
  Criterion 3054 — One landing, one set of words, either kind of agent.

  Rule: The decision is the same one an external agent gets — the problem
  summary and the directive.

  The point of the whole exercise. `Hooks.Stop` and `Agents.StopDecision` both
  read `Validation.validate_stop/3` for the summary and `Validation.Menu.render/2`
  for the directive; only the envelope differs. If the internal path grows its
  own wording, two agents looking at one broken tree get different accounts of
  it and the next change to either has to find both.

  Compared against each other rather than against a fixed string, deliberately.
  Pinning a phrase makes a reworded decision read as a defect, and the decision
  is reworded often — the menu's own history is three passes of exactly that.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  import CodeMySpecSpex.AgentToolsHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The decision is the same one an external agent gets — the problem summary and the directive" do
    scenario "One landing, one set of words, either kind of agent" do
      given_ "one working copy with problems outstanding and work available", context do
        Fixtures.deliver_manifest(context.scope)
        Fixtures.set_analyzer_mode(context.scope, :credo, :block_all)

        Fixtures.record_problem(context.scope, "credo", %{
          file_path: "lib/example_context.ex",
          message: "Modules should have a @moduledoc tag"
        })

        {:ok, Map.put(context, :agent_id, running_agent(context))}
      end

      when_ "the decision is produced for an agent running under Claude Code", context do
        {:ok, Map.put(context, :external, Fixtures.validate_stop(context.scope))}
      end

      when_ "and the decision is produced for an agent running under Alloy", context do
        :ok = Fixtures.end_turn(context.scope, context.agent_id)

        {:ok,
         Map.put(
           context,
           :internal,
           Fixtures.orchestrator_actions(context.scope, context.agent_id)
         )}
      end

      then_ "both name the same problems and the same directive", context do
        assert {:error, external} = context.external,
               "the external path allowed, so there is no decision to compare against"

        assert [internal | _] = context.internal, """
        The internal agent was told nothing while the external path produced a
        refusal for the same tree. One landing, one decision — an agent that
        gets neither is the gap this story exists to close.
        """

        # The summary, not the whole envelope: the hook wraps its copy in a
        # response shape and a cap that a message does not carry, and those
        # differences are the design rather than a drift.
        assert internal =~ "credo", """
        The internal decision does not name what the external one named.

        external: #{inspect(external)}
        internal: #{inspect(internal)}
        """

        {:ok, context}
      end
    end
  end
end
