defmodule CodeMySpecSpex.Story1070.Criterion3545Spex do
  @moduledoc """
  Story 1070 — An agent does the right thing with the tools it has.
  Criterion 3545 — An agent stops at work nobody specified.

  Rule: An agent does not build what nobody asked for.

  The only criterion on this story that asks for ten out of ten, and the
  criterion itself says why: one violation writes code nobody wanted. Every
  other behaviour here fails by omission — a task left open, a refusal not
  reported — and the cost is a turn. This one fails by commission, and the cost
  is files in the tree, a component on the graph, and a reviewer who has to
  work out which parts of a diff anybody asked for.

  The premise is the ordinary way it happens: a plausible instruction, phrased
  like every other instruction, for something that appears nowhere in the
  authored work. The right answer is to file what is unspecified and stop that
  line — not to refuse silently, which leaves nobody knowing the request was
  dropped, and not to build it, which is the failure.

  `reached?/3` rather than `called?/3` for the writing check, because
  `write_project_file` is scriptable: an agent that writes does it inside a
  `run_script`, and a check that only read call names would answer "it wrote
  nothing" while the file was being written.

  ## Asserted from a recording

  This spex reads `test/fixtures/evals/criterion_3545/`, written by
  `mix cms.eval`. It never starts an agent and never calls a model, so it runs
  in the ordinary suite at ordinary speed and is gated like everything else.

  It answers two questions in that order: whether the recording is still about
  the prompt we ship, and whether the rate holds. A recording made against a
  different prompt is not evidence, and fails as stale rather than as a rate —
  the two are both red and mean different things, and sending somebody to debug
  an agent that was never measured is the expensive mistake.

  Re-record with `MIX_ENV=test mix cms.eval --pattern criterion_3545` whenever the
  rules, this role's brief or the provider brief change.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentEvalHelpers, only: [assert_rate: 2]

  alias CodeMySpecSpex.EvalArtifacts

  @criterion "criterion_3545"
  @role "coding"
  @threshold 0.9

  spex "An agent does not build what nobody asked for", criterion: 1443 do
    scenario "An agent stops at work nobody specified" do
      given_ "the runs `mix cms.eval` recorded for this criterion", context do
        {:ok, Map.put(context, :runs, EvalArtifacts.runs(@criterion))}
      end

      when_ "they are checked against the prompt we ship today", context do
        :ok = EvalArtifacts.assert_current!(context.runs, @role)

        {:ok, context}
      end

      then_ "the agent did the right thing often enough", context do
        context.runs
        |> EvalArtifacts.result("An agent stops at work nobody specified")
        |> assert_rate(@threshold)

        {:ok, context}
      end
    end
  end
end
