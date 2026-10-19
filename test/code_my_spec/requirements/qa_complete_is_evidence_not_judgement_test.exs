defmodule CodeMySpec.Requirements.QaCompleteIsEvidenceNotJudgementTest do
  @moduledoc """
  `qa_complete` is decided by a QA submission, not by an agent saying so.

  It was `validation_type: :manual`, for a real reason: `execution_type:
  :sub_agent` means a sub-agent does the work, `Session.active_task/1` selects
  by status with no reference to `agent_id`, and the evaluator's only two
  answers were `:valid`, which completes, and `:invalid`, which files feedback
  against the parent. So the parent's own stop completed the QA sub-agent's live
  task before any attempt existed, discarding the run (7f79b855).

  The cure was worse than the disease. `Hooks.Stop.do_decide/6` allows a session
  holding a manual task out *before* validation runs, so for as long as a QA
  task was open, no spex, credo or exunit finding could block anybody — and
  nothing told the agent it was holding the task that did it.

  Measured 2026-08-28 on this machine: 44 of 55 main stops skipped the gate
  entirely across two sessions, and one session carried 21 cancelled
  `qa_complete` tasks against 5 completed — twenty-one starts nobody ever
  finished, each holding the gate open while it lived.

  So the requirement is automatic, and the evaluator got the third answer the
  guard always needed. These pin both halves; reverting either restores the
  hole.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Requirements.RequirementDefinitionData

  defp qa_complete do
    RequirementDefinitionData.story_graph()
    |> Enum.find(&(&1.name == "qa_complete"))
  end

  test "qa_complete is satisfied by evidence, not by an agent completing a task" do
    refute qa_complete().validation_type == :manual,
           "qa_complete is manual again. A session holding a manual task is allowed " <>
             "out of the stop hook before validation runs, so every open QA task " <>
             "switches off spex, credo and exunit for that session — and the agent is " <>
             "never told, because that branch returns an empty response. 'At least one " <>
             "valid DB-backed pass attempt exists' is a query; nothing about it needs " <>
             "a human to assert it."
  end

  test "and still says a sub-agent does the work" do
    assert qa_complete().execution_type == :sub_agent,
           "the sub-agent execution model is what made premature completion possible. " <>
             "If this changes, re-read why QaStory returns :skip before assuming it is " <>
             "still needed."
  end
end
