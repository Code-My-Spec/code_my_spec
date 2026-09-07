defmodule CodeMySpecSpex.Story1043.Criterion3057Spex do
  @moduledoc """
  Story 1043 — The stop decision reaches the agent running inside our own BEAM.
  Criterion 3057 — A clean stop is left alone.

  Rule: Nothing is delivered when there is nothing to say.

  The silence, and on this path it costs more than on the other one. An
  external agent's allowed stop is an empty body — story 894 settled that, and
  the cost of getting it wrong is a few bytes the model reads and ignores.

  Here a delivery is a *message*, and a message wakes the agent. An agent woken
  to be told its tree is clean and its work is finished has been charged a whole
  turn for no information, and the model that learns the orchestrator interrupts
  for nothing is the one that stops reading what it says.

  So this is the criterion that keeps the channel worth listening to.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  alias CodeMySpecSpex.Fixtures

  import CodeMySpecSpex.AgentToolsHelpers

  # See criterion 3059's note: `end_turn` re-triggers a full, real analyzer
  # pass, including a real recursive `mix spex` that has nothing to do with
  # this scenario.
  @end_turn_opts [
    compile_output_file: Path.expand("test/fixtures/validation/pipeline_clean_run/compile.jsonl"),
    spex_output_file: Path.expand("test/fixtures/validation/spex_green.jsonl")
  ]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Nothing is delivered when there is nothing to say" do
    scenario "A clean stop is left alone" do
      given_ "an agent running under Alloy with no task open", context do
        Fixtures.deliver_manifest(context.scope)

        {:ok, Map.put(context, :agent_id, running_agent(context))}
      end

      when_ "the analyzers complete with no problems", context do
        # Nothing seeded, so there is nothing outstanding. The turn ending is
        # what asks, and the answer is that there is nothing to report.
        :ok =
          use_cmd_cassette "clean", record: :none do
            Fixtures.end_turn(context.scope, context.agent_id, @end_turn_opts)
          end

        {:ok, context}
      end

      then_ "the agent is sent nothing", context do
        told = Fixtures.orchestrator_actions(context.scope, context.agent_id)

        assert told == [], """
        The agent was told something about a clean tree with no work open.
        Every delivery here wakes the agent and costs a turn, so a message with
        nothing in it is worse than one that never came — it teaches the model
        that the orchestrator interrupts for nothing.

        Got: #{inspect(told)}
        """

        {:ok, context}
      end

      then_ "and it is not woken", context do
        # Still idle. Something delivered would have started or queued a turn,
        # which `status/1` reports as busy or as work behind it.
        assert {:ok, %{busy?: false, queued: 0}} = Fixtures.agent_status(context.agent_id), """
        The agent has work in flight or stacked behind it after a stop that
        should have been silent, so something reached it anyway.
        """

        {:ok, context}
      end
    end
  end
end
