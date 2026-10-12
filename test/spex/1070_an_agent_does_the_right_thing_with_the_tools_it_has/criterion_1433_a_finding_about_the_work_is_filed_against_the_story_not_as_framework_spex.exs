defmodule CodeMySpecSpex.Story1070.Criterion3535Spex do
  @moduledoc """
  Story 1070 — An agent does the right thing with the tools it has.
  Criterion 3535 — A finding about the work is filed against the story, not as
  framework.

  Rule: An agent files a framework issue when the tooling is what is broken.

  The other side of 3534, and the reason that rule is about *which* backlog
  rather than about filing at all. Both scopes are one argument apart and an
  agent that gets the distinction backwards produces a framework backlog full
  of application defects — which reads as the harness being broken when it is
  not, and hides the ones that are.

  `app` is also where the requirement graph reads from: story issue submission readiness
  gates a story on the accepted issues filed against it, so a defect filed as
  `framework` leaves the story looking clean and ships.

  The premise is the ordinary one. An agent doing the work finds a defect in
  the thing it is building, which is the common case — most findings are about
  the application, and `framework` is the exception.

  ## Asserted from a recording

  This spex reads `test/fixtures/evals/criterion_3535/`, written by
  `mix cms.eval`. It never starts an agent and never calls a model, so it runs
  in the ordinary suite at ordinary speed and is gated like everything else.

  It answers two questions in that order: whether the recording is still about
  the prompt we ship, and whether the rate holds. A recording made against a
  different prompt is not evidence, and fails as stale rather than as a rate —
  the two are both red and mean different things, and sending somebody to debug
  an agent that was never measured is the expensive mistake.

  Re-record with `MIX_ENV=test mix cms.eval --pattern criterion_3535` whenever the
  rules, this role's brief or the provider brief change.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentEvalHelpers, only: [assert_rate: 2]

  alias CodeMySpecSpex.EvalArtifacts

  @criterion "criterion_3535"
  @role "coding"
  @threshold 0.8

  spex "An agent files a framework issue when the tooling is what is broken", criterion: 1433 do
    scenario "A finding about the work is filed against the story, not as framework" do
      given_ "the runs `mix cms.eval` recorded for this criterion", context do
        {:ok, Map.put(context, :runs, EvalArtifacts.runs(@criterion))}
      end

      when_ "they are checked against the prompt we ship today", context do
        :ok = EvalArtifacts.assert_current!(context.runs, @role)

        {:ok, context}
      end

      then_ "the agent did the right thing often enough", context do
        context.runs
        |> EvalArtifacts.result(
          "A finding about the work is filed against the story, not as framework"
        )
        |> assert_rate(@threshold)

        {:ok, context}
      end
    end
  end
end
