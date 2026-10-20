defmodule CodeMySpec.Qa.AStaleAttemptSaysWhyItIsStaleTest do
  @moduledoc """
  Issue 746895bf: story 1123's passing QA attempt read `stale: true` with HEAD
  unchanged, and nothing said why. Staleness is the attempt's review against the
  story's own certification when it was submitted: not main, and not the copy's
  HEAD. `list_qa_attempts` now names the two commits.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Qa.Tools.ListQaAttempts
  alias CodeMySpec.Qa.Verdict

  @reviewed "22121a349b72678186298086f4551c01fa2eee06"
  @certified "f553549b3a1c0de0000000000000000000000000"
  @at ~U[2026-10-18 18:22:05.957266Z]

  defp attempt(attrs \\ %{}) do
    Map.merge(
      %{stale: true, reviewed_commit: @reviewed, review_certified_at: @at},
      attrs
    )
  end

  describe "stale_reason/2" do
    test "an attempt that is not stale needs no reason" do
      assert ListQaAttempts.stale_reason(attempt(%{stale: false}), %{qa_ready_commit: @reviewed}) ==
               nil
    end

    test "a pass on an earlier certification names both commits" do
      reason = ListQaAttempts.stale_reason(attempt(), %{qa_ready_commit: @certified})

      assert reason =~ "reviewed commit #{@reviewed}"
      assert reason =~ "certified at #{@certified}"
      assert reason =~ "unless nothing QA exercises changed"
    end

    test "a story no longer certified says so" do
      assert ListQaAttempts.stale_reason(attempt(), %{qa_ready_commit: nil}) =~
               "not certified for QA now"
    end

    test "the same commit re-certified, or fixes that moved, is named as such" do
      reason = ListQaAttempts.stale_reason(attempt(), %{qa_ready_commit: @reviewed})

      assert reason =~ "which has since been replaced"
      assert reason =~ "issue fixes it saw"
    end

    test "an attempt with no recorded review says it cannot be matched" do
      assert ListQaAttempts.stale_reason(attempt(%{reviewed_commit: nil}), %{
               qa_ready_commit: @certified
             }) =~ "no review was recorded"
    end
  end

  describe "what a review is compared with" do
    test "only the story's certification and the fixes submitted: nothing landing on main" do
      story = %{qa_ready_commit: @reviewed, qa_ready_at: @at, qa_reviewed_commit: nil}
      review = %{commit: @reviewed, certified_at: @at, submissions: %{}}

      assert Verdict.review_current?(story, review, %{})

      # Another story landing on main changes none of these inputs.
      assert Verdict.review_current?(story, review, %{})
      refute Verdict.review_current?(%{story | qa_ready_commit: @certified}, review, %{})
    end
  end
end
