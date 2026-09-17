defmodule CodeMySpecSpex.Story1070.Criterion3538Spex do
  @moduledoc """
  Story 1070 — An agent does the right thing with the tools it has.
  Criterion 3538 — An agent that only sometimes does the right thing is a
  finding about the prompt.

  Rule: A behaviour is asserted as a rate over repeated runs, not a single pass.

  The reason the rate is worth measuring at all, and the half of it that is
  easiest to lose.

  A behaviour that holds six times in ten is not a flake. It means the agent
  read the instruction one way sometimes and another way the rest of the time,
  which is a statement about the prompt being ambiguous — and it is precisely
  the information a single-run test cannot produce. The failure mode this
  criterion protects against is the ordinary one: re-run until green, mark it
  flaky, move on. Doing that discards the only measurement that was ever taken.

  So the report has to say it in those words. An agent that never does the
  thing and an agent that half does it need different work, and a message that
  reads the same for both sends whoever gets it to the wrong place.

  Not tagged `:eval` for the same reason 3537 is not: the subject is the
  reporting, the agent's answers are its input, and a rule about how a result
  is described should break in the ordinary suite the moment the description
  changes.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentEvalHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A behaviour is asserted as a rate over repeated runs, not a single pass" do
    scenario "An agent that only sometimes does the right thing is a finding about the prompt" do
      given_ "a criterion whose measured rate is neither near zero nor near one", context do
        ambiguous =
          measure("a behaviour the agent is of two minds about", fn run ->
            {rem(run, 2) == 0, "run #{run}: called something else"}
          end)

        assert ambiguous.rate == 0.5,
               "the premise is a rate in the middle; this one is #{ambiguous.rate}"

        {:ok, Map.put(context, :ambiguous, ambiguous)}
      end

      when_ "the result is reported", context do
        reported =
          assert_raise ExUnit.AssertionError, fn ->
            assert_rate(context.ambiguous, 0.9)
          end

        {:ok, Map.put(context, :reported, reported.message)}
      end

      then_ "it is recorded as ambiguity in the prompt, not as a flake", context do
        said = context.reported

        assert said =~ "ambiguous",
               """
               A rate of 50% was reported without naming what it means.

               Half-and-half is the prompt being read two ways, and that is the
               finding — the one thing a single run can never tell you. A report
               that does not say so leaves the reader to guess, and the guess
               everybody makes is "flaky".

               Got:
               #{said}
               """

        assert said =~ ~r/do not re-?run/i,
               """
               The report did not rule out running it again.

               Stated rather than merely omitted, because re-running until it
               passes is the obvious thing to do with an intermittent result
               and it discards the measurement. The rate is the answer; it
               moves when the ambiguity is fixed, and not before.

               Got:
               #{said}
               """

        assert said =~ ~r/not (a )?flak|do not.*flak/i,
               """
               The report did not rule out calling this flaky.

               It has to, explicitly: an intermittent behaviour looks exactly
               like a flaky test, and the whole value of the measurement is
               lost the moment somebody files it as one.

               Got:
               #{said}
               """

        {:ok, context}
      end
    end
  end
end
