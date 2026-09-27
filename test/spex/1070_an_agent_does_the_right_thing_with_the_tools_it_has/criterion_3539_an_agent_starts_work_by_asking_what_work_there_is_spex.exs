defmodule CodeMySpecSpex.Story1070.Criterion3539Spex do
  @moduledoc """
  Story 1070 — An agent does the right thing with the tools it has.
  Criterion 3539 — An agent starts work by asking what work there is.

  Rule: An agent claims work before it does the work.

  The first thing every agent does, and the one nothing has ever checked. The
  whole harness rests on it: the graph decides what is next, `start_task`
  records who is on it, and the stop hook evaluates what came back. An agent
  that picks its own work instead gets none of that — two agents land on the
  same requirement, and the one that finishes has nothing to close.

  ## Asserted from a recording

  This spex reads `test/fixtures/evals/criterion_3539/`, written by
  `mix cms.eval`. It never starts an agent and never calls a model, so it runs
  in the ordinary suite at ordinary speed and is gated like everything else.

  It answers two questions in that order: whether the recording is still about
  the prompt we ship, and whether the rate holds. A recording made against a
  different prompt is not evidence, and fails as stale rather than as a rate —
  the two are both red and mean different things, and sending somebody to debug
  an agent that was never measured is the expensive mistake.

  Re-record with `MIX_ENV=test mix cms.eval --pattern criterion_3539` whenever the
  rules, this role's brief or the provider brief change.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentEvalHelpers, only: [assert_rate: 2]

  alias CodeMySpecSpex.EvalArtifacts

  @criterion "criterion_3539"
  @role "coding"
  @threshold 0.9

  spex "An agent claims work before it does the work" do
    scenario "An agent starts work by asking what work there is" do
      given_ "the runs `mix cms.eval` recorded for this criterion", context do
        {:ok, Map.put(context, :runs, EvalArtifacts.runs(@criterion))}
      end

      when_ "they are checked against the prompt we ship today", context do
        :ok = EvalArtifacts.assert_current!(context.runs, @role)

        {:ok, context}
      end

      then_ "the agent did the right thing often enough", context do
        context.runs
        |> EvalArtifacts.result("An agent starts work by asking what work there is")
        |> assert_rate(@threshold)

        {:ok, context}
      end
    end
  end
end
