defmodule CodeMySpec.Problems.ProblemRendererWaitRemedyTest do
  @moduledoc """
  The wait remedy has two renderings, and which one is used depends on who is
  waiting.

  `Hooks.Stop`'s remedy for a stale source with a rerun in flight is "curl
  `analysis/wait` in the background, then stop again". That is the only thing an
  external agent can do: a hook must answer now, and nothing will come back to
  it later.

  Story 988 says it must have no counterpart for an agent running under Alloy —
  "an internal agent never waits: it stops, analysis runs, the message arrives".
  QA of that story watched one obey the directive anyway. It curled the
  endpoint, was notified, curled it again, and spent its whole turn on it while
  the orchestrator was already waiting on the same run. Issue `778ab035`.

  Asserted here rather than in criterion 3056's spex because reaching the branch
  needs a source genuinely in flight, and `Analysis.in_flight/1` reads the
  analysis Registry rather than the ledger — with no ProjectServer for the
  project the state is `:untracked`, so no fixture row can put a source in
  flight from a spex. The renderer is a pure function and takes the flight state
  as options, so the two renderings can simply be asked for.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.Problems.ProblemRenderer

  @working_copy_id "16bce3db-8212-469b-a6dd-c6a4a4b3a499"

  defp finding do
    %Problem{
      source: "credo",
      file_path: "lib/example_context.ex",
      line: 1,
      message: "Modules should have a @moduledoc tag.",
      severity: :error
    }
  end

  # A stale source with a rerun of that same source in flight — the only state
  # that renders a remedy at all.
  defp opts(extra) do
    Keyword.merge(
      [
        stale_sources: ["credo"],
        in_flight: ["credo"],
        working_copy_id: @working_copy_id,
        tracked?: true
      ],
      extra
    )
  end

  test "an external agent is told to wait for the run itself" do
    rendered = ProblemRenderer.render_stop_response([finding()], [], opts([]))

    assert rendered =~ "analysis/wait",
           "the external path lost its remedy; that endpoint is the only way a " <>
             "hook-driven agent can find out. Got:\n#{rendered}"

    assert rendered =~ "stop again",
           "waiting is only half the remedy — the agent has to stop again afterwards"
  end

  test "an agent the orchestrator is already waiting for is not told to wait" do
    rendered =
      ProblemRenderer.render_stop_response([finding()], [], opts(internal_agent?: true))

    refute rendered =~ "analysis/wait", """
    The internal agent was handed the hook's wait directive. It is a live
    process the orchestrator delivers to; telling it to block on the endpoint
    and stop again buys nothing and costs a turn, which is exactly what QA
    watched happen. Got:

    #{rendered}
    """

    refute rendered =~ "curl", "the internal agent was handed a shell command to run"

    refute rendered =~ "stop again", """
    The internal agent was told to end another turn to learn what the last one
    broke. That is the one-turn-late problem, arriving on the path story 988
    says is free of it.

    #{rendered}
    """

    assert rendered =~ "you will be told what it found",
           "the agent was left with no account of what happens next:\n#{rendered}"
  end

  test "the internal agent is no longer told it owns the checkout" do
    # Production always passes a `session_paths` set for an internal agent now:
    # `Validation.session_paths/3` answers from `FileEdits` rather than `nil`,
    # so the agent gets the same attribution note an external session gets.
    #
    # This asserts the claim that used to be made here is gone. While the
    # internal path could not tell what an agent had edited, the note told it it
    # owned the whole checkout — true of the code at the time and never true of
    # a product agent, which is what handed one 160 findings it had never seen.
    rendered =
      ProblemRenderer.render_stop_response(
        [finding()],
        [],
        opts(internal_agent?: true, session_paths: MapSet.new())
      )

    refute rendered =~ "owns the checkout it works in", """
    The agent was told it owns the whole checkout. Ownership is decided by what
    it edited now, not by which path the decision came down, and this sentence
    outlived the rule it described.

    #{rendered}
    """

    refute rendered =~ "scope `framework`",
           "the agent was invited to file a framework issue about a state that is not a defect"
  end

  test "both renderings still name the finding and that a rerun is in flight" do
    for extra <- [[], [internal_agent?: true]] do
      rendered = ProblemRenderer.render_stop_response([finding()], [], opts(extra))

      assert rendered =~ "Modules should have a @moduledoc tag.",
             "the finding itself must survive either rendering: #{inspect(extra)}"

      assert rendered =~ "rerun is in flight",
             "both agents are entitled to know a rerun is coming: #{inspect(extra)}"
    end
  end
end
