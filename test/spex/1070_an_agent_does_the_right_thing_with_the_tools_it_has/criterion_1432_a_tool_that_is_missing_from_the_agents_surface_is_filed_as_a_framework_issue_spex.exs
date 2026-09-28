defmodule CodeMySpecSpex.Story1070.Criterion3534Spex do
  @moduledoc """
  Story 1070 — An agent does the right thing with the tools it has.
  Criterion 3534 — A tool that is missing from the agent's surface is filed as
  a framework issue.

  Rule: An agent files a framework issue when the tooling is what is broken.

  Where 3543's report has to land. Saying it in a reply reaches nobody — the
  conversation ends with the turn — so the only durable form is an issue, and
  the only useful scope is `framework`, because the thing that is broken is the
  harness rather than the application being built.

  Filing it against the story the agent happened to be working is the failure
  this rules out, and it is the tempting one: the story is in front of the
  agent, `story_id` is right there, and the issue then blocks a story that has
  nothing to do with the fault while the fault goes unlisted in the framework
  backlog. Every one of the six prior instances recorded in
  `CmsHarness.Agents.Engine.tools/1` was found by a person hitting it again
  rather than by reading a list.

  The premise is a tool named to the agent that does not exist anywhere. That
  is exactly the shape of the incident (`23f5544e`): the stop menu named
  `list_tasks` to a surface that did not carry it. Naming one here reproduces
  the premise without needing a real absence in the tree to still be there.

  ## Asserted from a recording

  This spex reads `test/fixtures/evals/criterion_3534/`, written by
  `mix cms.eval`. It never starts an agent and never calls a model, so it runs
  in the ordinary suite at ordinary speed and is gated like everything else.

  It answers two questions in that order: whether the recording is still about
  the prompt we ship, and whether the rate holds. A recording made against a
  different prompt is not evidence, and fails as stale rather than as a rate —
  the two are both red and mean different things, and sending somebody to debug
  an agent that was never measured is the expensive mistake.

  Re-record with `MIX_ENV=test mix cms.eval --pattern criterion_3534` whenever the
  rules, this role's brief or the provider brief change.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentEvalHelpers, only: [assert_rate: 2]

  alias CodeMySpecSpex.EvalArtifacts

  @criterion "criterion_3534"
  @role "coding"
  @threshold 0.8

  spex "An agent files a framework issue when the tooling is what is broken", criterion: 1432 do
    scenario "A tool that is missing from the agent's surface is filed as a framework issue" do
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
          "A tool that is missing from the agent's surface is filed as a framework issue"
        )
        |> assert_rate(@threshold)

        {:ok, context}
      end
    end
  end
end
