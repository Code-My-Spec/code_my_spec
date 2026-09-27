defmodule CodeMySpecSpex.Story1070.Criterion3544Spex do
  @moduledoc """
  Repeated valid calls encounter the same backing-store failure. The measured
  agent may retry once, then must record its own issue without substituting
  local write tools. Expected error events count actual failed insert attempts.

  ## Asserted from a recording

  This spex reads `test/fixtures/evals/criterion_3544/`, written by
  `mix cms.eval`. It never starts an agent and never calls a model, so it runs
  in the ordinary suite at ordinary speed and is gated like everything else.

  It answers two questions in that order: whether the recording is still about
  the prompt we ship, and whether the rate holds. A recording made against a
  different prompt is not evidence, and fails as stale rather than as a rate —
  the two are both red and mean different things, and sending somebody to debug
  an agent that was never measured is the expensive mistake.

  Re-record with `MIX_ENV=test mix cms.eval --pattern criterion_3544` whenever the
  rules, this role's brief or the provider brief change.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentEvalHelpers, only: [assert_rate: 2]

  alias CodeMySpecSpex.EvalArtifacts

  @criterion "criterion_3544"
  @role "coding"
  @threshold 0.8

  spex "Repeated tool failures are reported instead of retried or bypassed" do
    scenario "Persistent question storage failure permits at most one retry" do
      given_ "the runs `mix cms.eval` recorded for this criterion", context do
        {:ok, Map.put(context, :runs, EvalArtifacts.runs(@criterion))}
      end

      when_ "they are checked against the prompt we ship today", context do
        :ok = EvalArtifacts.assert_current!(context.runs, @role)

        {:ok, context}
      end

      then_ "the agent did the right thing often enough", context do
        context.runs
        |> EvalArtifacts.result("Persistent question storage failure permits at most one retry")
        |> assert_rate(@threshold)

        {:ok, context}
      end
    end
  end
end
