defmodule CodeMySpecSpex.Story1070.Criterion3540Spex do
  @moduledoc """
  Story 1070 — An agent does the right thing with the tools it has.
  Criterion 3540 — An agent that finishes work closes the task.

  Rule: An agent closes the work it finished.

  The other end of 3539, and the one that costs more when it is missing. An
  open task is what the harness evaluates: the stop hook checks the output, the
  graph learns the requirement moved, and the next agent is offered something
  else. An agent that does the work and walks away leaves the requirement
  looking untouched and the task looking abandoned, which is the state four
  tasks sat in on 2026-09-16.

  Closing before taking more is the second half and is separately assertable.
  An agent holding two open tasks has told the graph it is doing two things and
  can finish at most one of them, so the ordering is the claim rather than the
  presence of both calls.

  ## Asserted from a recording

  This spex reads `test/fixtures/evals/criterion_3540/`, written by
  `mix cms.eval`. It never starts an agent and never calls a model, so it runs
  in the ordinary suite at ordinary speed and is gated like everything else.

  It answers two questions in that order: whether the recording is still about
  the prompt we ship, and whether the rate holds. A recording made against a
  different prompt is not evidence, and fails as stale rather than as a rate —
  the two are both red and mean different things, and sending somebody to debug
  an agent that was never measured is the expensive mistake.

  Re-record with `MIX_ENV=test mix cms.eval --pattern criterion_3540` whenever the
  rules, this role's brief or the provider brief change.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentEvalHelpers, only: [assert_rate: 2]

  alias CodeMySpecSpex.EvalArtifacts

  @criterion "criterion_3540"
  @role "product"
  @threshold 0.9

  spex "An agent closes the work it finished", criterion: 1438 do
    scenario "An agent that finishes work closes the task" do
      given_ "the runs `mix cms.eval` recorded for this criterion", context do
        {:ok, Map.put(context, :runs, EvalArtifacts.runs(@criterion))}
      end

      when_ "they are checked against the prompt we ship today", context do
        :ok = EvalArtifacts.assert_current!(context.runs, @role)

        {:ok, context}
      end

      then_ "the agent did the right thing often enough", context do
        context.runs
        |> EvalArtifacts.result("An agent that finishes work closes the task")
        |> assert_rate(@threshold)

        {:ok, context}
      end
    end
  end
end
