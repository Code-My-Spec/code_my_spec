defmodule CodeMySpec.Agents.QaCanStartAFocusedAnalysisRunTest do
  @moduledoc """
  Issue 7b9b7c89: QA had no supported route to submit a focused validation.

  `start_analysis` already accepted `paths` to scope a run to one file
  (issue 56a2d806's companion fix, 08d1676cc), but QA's role did not carry
  the tool at all -- so a QA agent directed to validate one assigned test
  "through the supported analysis queue" had no tool to call. Running the
  test through bash would bypass the queue; starting a full `exunit` sweep
  would exceed the authorized focused scope.

  Per product's decision (question 0370d65d): grant QA `start_analysis`.
  QA calls it with `paths` set to the assigned file, waits for the result
  message, and cites that run when it calls `submit_qa_result` or
  `submit_issue_qa_result`.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Agents.ToolSets

  test "qa may start an analysis run, scoped to the paths it was assigned" do
    assert "start_analysis" in ToolSets.for_role(:qa),
           "a qa agent directed to validate one assigned test through the supported " <>
             "analysis queue has to be able to start a run for it"
  end
end
