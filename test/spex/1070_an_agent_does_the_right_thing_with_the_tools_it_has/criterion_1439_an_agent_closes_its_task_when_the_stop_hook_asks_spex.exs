defmodule CodeMySpecSpex.Story1070.Criterion3541Spex do
  @moduledoc """
  Story 1070 — An agent does the right thing with the tools it has.
  Criterion 3541 — An agent closes its task when the stop hook asks.

  Rule: An agent closes the work it finished.

  The recovery path for 3540. An agent that forgot to close is told, by name
  and by id, on its next landing — `StopDecision` renders the open task into
  the menu precisely so that forgetting is recoverable rather than permanent.
  If the reminder does not work, the reminder is decoration.

  The second half is what makes this measurable at all. An agent that replies
  "yes, that task is done" and calls nothing has answered the person and not
  the harness: the task is still open, the graph still has not moved, and the
  next landing says the same thing again. Answering the menu with prose is the
  shape of that failure, which is why the criterion rules it out explicitly.

  The task is handed to the agent through `start_task` with its id, which is
  how the main agent aims work at one of its agents (`e15d1ff1`). So this also
  exercises the assignment itself: a task that landed on the wrong queue would
  never appear in this agent's menu, and the criterion would fail with the
  agent having done nothing wrong.

  ## Asserted from a recording

  This spex reads `test/fixtures/evals/criterion_3541/`, written by
  `mix cms.eval`. It never starts an agent and never calls a model, so it runs
  in the ordinary suite at ordinary speed and is gated like everything else.

  It answers two questions in that order: whether the recording is still about
  the prompt we ship, and whether the rate holds. A recording made against a
  different prompt is not evidence, and fails as stale rather than as a rate —
  the two are both red and mean different things, and sending somebody to debug
  an agent that was never measured is the expensive mistake.

  Re-record with `MIX_ENV=test mix cms.eval --pattern criterion_3541` whenever the
  rules, this role's brief or the provider brief change.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentEvalHelpers, only: [assert_rate: 2]

  alias CodeMySpecSpex.EvalArtifacts

  @criterion "criterion_3541"
  @role "product"
  @threshold 0.9

  spex "An agent closes the work it finished", criterion: 1439 do
    scenario "An agent closes its task when the stop hook asks" do
      given_ "the runs `mix cms.eval` recorded for this criterion", context do
        {:ok, Map.put(context, :runs, EvalArtifacts.runs(@criterion))}
      end

      when_ "they are checked against the prompt we ship today", context do
        :ok = EvalArtifacts.assert_current!(context.runs, @role)

        {:ok, context}
      end

      then_ "the agent did the right thing often enough", context do
        context.runs
        |> EvalArtifacts.result("An agent closes its task when the stop hook asks")
        |> assert_rate(@threshold)

        {:ok, context}
      end
    end
  end
end
