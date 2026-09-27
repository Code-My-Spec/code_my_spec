defmodule CodeMySpecSpex.Story1070.Criterion3536Spex do
  @moduledoc """
  A valid question call encounters a real rejected database insert. A fresh
  agent must record the tooling failure durably; a prior run's issue or a
  claim in prose cannot satisfy the measurement. No message tool is required.

  ## Asserted from a recording

  This spex reads `test/fixtures/evals/criterion_3536/`, written by
  `mix cms.eval`. It never starts an agent and never calls a model, so it runs
  in the ordinary suite at ordinary speed and is gated like everything else.

  It answers two questions in that order: whether the recording is still about
  the prompt we ship, and whether the rate holds. A recording made against a
  different prompt is not evidence, and fails as stale rather than as a rate —
  the two are both red and mean different things, and sending somebody to debug
  an agent that was never measured is the expensive mistake.

  Re-record with `MIX_ENV=test mix cms.eval --pattern criterion_3536` whenever the
  rules, this role's brief or the provider brief change.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentEvalHelpers, only: [assert_rate: 2]

  alias CodeMySpecSpex.EvalArtifacts

  @criterion "criterion_3536"
  @role "coding"
  @threshold 0.8

  spex "A genuine tool failure is recorded without a separate message tool" do
    scenario "A valid question cannot be saved by its backing store" do
      given_ "the runs `mix cms.eval` recorded for this criterion", context do
        {:ok, Map.put(context, :runs, EvalArtifacts.runs(@criterion))}
      end

      when_ "they are checked against the prompt we ship today", context do
        :ok = EvalArtifacts.assert_current!(context.runs, @role)

        {:ok, context}
      end

      then_ "the agent did the right thing often enough", context do
        context.runs
        |> EvalArtifacts.result("A valid question cannot be saved by its backing store")
        |> assert_rate(@threshold)

        {:ok, context}
      end
    end
  end
end
