defmodule CodeMySpecSpex.Story1070.Criterion3543Spex do
  @moduledoc """
  Story 1070 — An agent does the right thing with the tools it has.
  Criterion 3543 — An agent told to call a tool it does not carry says so.

  Rule: An agent reports a tool that will not work rather than routing around it.

  The behaviour that cost the most on 2026-09-16 when it was absent, and the
  one nothing currently protects.

  Every agent carries nineteen tools directly and can reach the rest through
  `run_script`. Its prompt names all of them, so "call `create_issue`" is an
  ordinary instruction and a direct call to it is an ordinary mistake — the
  server answers "This server has no tool called …", which is the same sentence
  a genuinely missing tool answers with. What the agent does next is the whole
  criterion: reach it the way it is reachable, and say what happened, rather
  than concluding its bindings are broken and standing down. Two agents stood
  down on that sentence, and one lost a day (`23f5544e`).

  Measured against a lower threshold than the claiming criteria on purpose.
  This is recovery from a surprise rather than the ordinary path, and eight in
  ten is an agent that recovers reliably enough to be left alone overnight.

  ## Asserted from a recording

  This spex reads `test/fixtures/evals/criterion_3543/`, written by
  `mix cms.eval`. It never starts an agent and never calls a model, so it runs
  in the ordinary suite at ordinary speed and is gated like everything else.

  It answers two questions in that order: whether the recording is still about
  the prompt we ship, and whether the rate holds. A recording made against a
  different prompt is not evidence, and fails as stale rather than as a rate —
  the two are both red and mean different things, and sending somebody to debug
  an agent that was never measured is the expensive mistake.

  Re-record with `MIX_ENV=test mix cms.eval --pattern criterion_3543` whenever the
  rules, this role's brief or the provider brief change.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentEvalHelpers, only: [assert_rate: 2]

  alias CodeMySpecSpex.EvalArtifacts

  @criterion "criterion_3543"
  @role "coding"
  @threshold 0.8

  spex "An agent reports a tool that will not work rather than routing around it",
    criterion: 1441 do
    scenario "An agent told to call a tool it does not carry says so" do
      given_ "the runs `mix cms.eval` recorded for this criterion", context do
        {:ok, Map.put(context, :runs, EvalArtifacts.runs(@criterion))}
      end

      when_ "they are checked against the prompt we ship today", context do
        :ok = EvalArtifacts.assert_current!(context.runs, @role)

        {:ok, context}
      end

      then_ "the agent did the right thing often enough", context do
        context.runs
        |> EvalArtifacts.result("An agent told to call a tool it does not carry says so")
        |> assert_rate(@threshold)

        {:ok, context}
      end
    end
  end
end
