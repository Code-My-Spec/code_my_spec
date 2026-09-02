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

  alias CodeMySpecSpex.Fixtures

  import CodeMySpecSpex.AgentToolsHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "When the run completes, the decision reaches the agent as a message" do
    scenario "The answer arrives when it exists, not when it was asked for" do
      given_ "an agent running under Alloy whose copy has problems outstanding", context do
        Fixtures.deliver_manifest(context.scope)
        Fixtures.set_analyzer_mode(context.scope, :credo, :block_all)

        Fixtures.record_problem(context.scope, "credo", %{
          file_path: "lib/example_context.ex",
          message: "Modules should have a @moduledoc tag"
        })

        {:ok, Map.put(context, :agent_id, running_agent(context))}
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
