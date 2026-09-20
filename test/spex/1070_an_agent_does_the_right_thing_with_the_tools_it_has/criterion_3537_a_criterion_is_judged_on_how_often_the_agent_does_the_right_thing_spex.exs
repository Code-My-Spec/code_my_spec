defmodule CodeMySpecSpex.Story1070.Criterion3537Spex do
  @moduledoc """
  Story 1070 — An agent does the right thing with the tools it has.
  Criterion 3537 — A criterion is judged on how often the agent does the right thing.

  Rule: A behaviour is asserted as a rate over repeated runs, not a single pass.

  The rule the other ten criteria are measured under, so it is the one that has
  to hold first. A single green run says a behaviour is *possible*. This story
  claims something stronger — that the behaviour is reliable — and the only way
  to say that about a non-deterministic agent is to count.

  ## What is under test here, and what is not

  The agent's own conduct is the *input* to this criterion rather than its
  subject: what is being judged is the judging. So the runs below answer from a
  fixed sequence instead of starting agents, and that is not a manufactured
  example of agent behaviour — it is the only way to state a scoring rule about
  a proportion whose value has to be chosen rather than rolled.

  Which is also why this one is not tagged `:eval`. It costs milliseconds, it
  is deterministic, and it should break the moment somebody makes
  `assert_rate/2` accept a rate below its threshold — including on a run of the
  ordinary suite.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentEvalHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A behaviour is asserted as a rate over repeated runs, not a single pass" do
    scenario "A criterion is judged on how often the agent does the right thing" do
      given_ "a criterion whose agent did the right thing in eight runs of ten", context do
        held = [true, true, false, true, true, true, true, false, true, true]

        {:ok, Map.put(context, :held, held)}
      end

      when_ "the scenario is run repeatedly against the same seeded project", context do
        measured =
          measure("a behaviour under measurement", 10, fn run ->
            {Enum.at(context.held, run - 1), "run #{run}"}
          end)

        {:ok, Map.put(context, :measured, measured)}
      end

      then_ "the result is the proportion, and the threshold decides", context do
        assert context.measured.runs == 10,
               """
               The measurement did not run ten times, so its proportion is over a
               different denominator than the criteria state their thresholds
               against. Got #{context.measured.runs}.
               """

        assert context.measured.rate == 0.8,
               """
               Eight runs in ten held and the result says #{context.measured.rate}.

               The proportion is the whole answer this story produces. A count
               that does not match what happened makes every threshold below it
               meaningless.
               """

        assert_rate(context.measured, 0.8)

        assert_raise ExUnit.AssertionError, fn -> assert_rate(context.measured, 0.9) end

        {:ok, context}
      end
    end
  end
end
