defmodule CodeMySpec.Promotion.ARedGateNamesItsFindingsTest do
  @moduledoc """
  Issue 4a18b91a: an ejection that said "the batch's analysis found problems
  in your changes:" named none of them. Traced as far as the code on this
  branch allows: `Promotion.gate/3`'s own red-path reason
  (`gate_result/2`) already inlines `describe_problems/1`, and every problem
  `blocking_problems/2` can return already carries a `source` that is a
  member of `Run.sources()` -- the only thing `describe_problems/1` filters
  on -- so an empty findings section for a non-empty problem list could not
  be reproduced here. This pins the real function the queue calls
  (`PromotionQueue.Worker`'s `case Promotion.gate(batch.scope, batch.head)
  do {:error, reason} -> red(state, reason) end`) so a future regression in
  that path, or in `describe_problems/1`'s filtering, is caught rather than
  silently reintroduced.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.AnalysisFixtures
  import CodeMySpec.ProblemsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.Promotion

  test "a gate refusal names the file, line and message of each blocking problem" do
    scope = full_scope_fixture()
    head = String.duplicate("a", 40)

    fresh_analysis_runs_fixture(scope, Run.sources(), commit: head)

    problem_fixture(scope, %{
      source: "exunit",
      source_type: :test,
      severity: :error,
      file_path: "test/widget_test.exs",
      line: 7,
      message: "1) test widget renders (WidgetTest)"
    })

    assert {:error, %{reason: reason}} = Promotion.gate(scope, head)

    assert reason =~ "exunit (1)",
           "the refusal does not even name the source carrying the problem. Got: #{reason}"

    assert reason =~ "test/widget_test.exs:7",
           "the refusal names no location for its own finding. Got: #{reason}"

    assert reason =~ "1) test widget renders",
           "the refusal names no message for its own finding. Got: #{reason}"
  end
end
