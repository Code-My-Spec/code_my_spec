defmodule CodeMySpecSpex.Story1043.Criterion3052Spex do
  @moduledoc """
  Story 1043 — The stop decision reaches the agent running inside our own BEAM.
  Criterion 3052 — The answer arrives when it exists, not when it was asked for.

  Rule: When the run completes, the decision reaches the agent as a message.

  The delivery half. `Hooks.Stop` produces this same value for an external agent
  and wraps it in the hook protocol's envelope; an agent running under Alloy
  fires no hooks, so `Validation.validate_stop/3` — whose only two callers were
  hooks — never ran for one, and a turn that should have been blocked just
  ended.

  What arrives is a message into the agent's own queue, which is the whole of
  the design: same decision, different transport.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures

  import CodeMySpecSpex.AgentToolsHelpers

  @impl_path "lib/example_context.ex"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "When the run completes, the decision reaches the agent as a message" do
    scenario "The answer arrives when it exists, not when it was asked for" do
      given_ "an agent running under Alloy whose copy has problems outstanding", context do
        # Lifted from story 988's criterion 8201, which is the proven recipe for
        # a finding that actually blocks. Every step matters and I had been
        # missing the last one: without a *fresh* analysis run credo is stale,
        # and a stale source does not block — which is that story's whole
        # subject and the reason four scenarios here allowed for a reason that
        # had nothing to do with what they test.
        Fixtures.set_analyzer_mode(context.scope, :credo, :block_all)

        :ok =
          Environments.write_file(
            context.environment,
            @impl_path,
            "defmodule ExampleContext do\nend\n"
          )

        Fixtures.deliver_manifest(context.scope)
        Fixtures.record_problem(context.scope, "credo", %{file_path: @impl_path})
        Fixtures.fresh_analysis_runs(context.scope, ["credo"])

        # The premise, asserted. 8201 does this too, and for the reason it
        # gives: if the finding does not block first, the scenario proves
        # nothing about what the agent is told.
        assert {:error, _} = Fixtures.validate_stop(context.scope),
               "the finding must actually block first, or this scenario proves nothing"

        agent_id = running_agent(context)
        # The agent wrote the file the finding is about.
        #
        # Recorded because that is now what makes a finding its own:
        # `block_changed` narrows to what the agent edited, and `FileEdits`
        # learns that from its `write` and `edit` calls. Without this the
        # finding belongs to nobody, is demoted to advisory, and everything
        # below asserts against silence.
        Fixtures.record_agent_edit(agent_id, @impl_path)

        {:ok, Map.put(context, :agent_id, agent_id)}
      end

      when_ "its turn ends", context do
        :ok = Fixtures.end_turn(context.scope, context.agent_id)

        {:ok, context}
      end

      then_ "the agent is sent the decision", context do
        told = Fixtures.orchestrator_actions(context.scope, context.agent_id)

        assert told != [], """
        The turn ended with problems outstanding and the agent was told
        nothing. An external agent in the same position is refused its stop and
        handed the summary; this one walks away from a broken tree, which is
        what story 890's parent issue described and what this story exists to
        end.
        """

        assert Enum.any?(told, &(&1 =~ "credo")),
               "something reached the agent, but not the finding: #{inspect(told)}"

        {:ok, context}
      end
    end
  end
end
