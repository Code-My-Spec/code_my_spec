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

defmodule CodeMySpec.AgentTasks.QaStorySubagentSkipTest do
  @moduledoc """
  A QA task a sub-agent owns is left alone by anybody else's stop.

  This is the half that makes `qa_complete` safe to evaluate automatically. The
  parent's stop iterates every task on the session regardless of which agent is
  stopping, so without an answer meaning "not mine", it completed the
  sub-agent's live task before any attempt existed.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.AccountsFixtures
  import CodeMySpec.ProjectsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.QaStory
  alias CodeMySpec.Users.Scope

  setup do
    user = user_fixture()
    account = account_fixture(%{name: "Skip #{System.unique_integer([:positive])}"})

    scope = %Scope{
      user: user,
      user_id: user.id,
      active_account: account,
      active_account_id: account.id
    }

    project = project_fixture(scope)
    {:ok, scope: %Scope{scope | active_project: project, active_project_id: project.id}}
  end

  test "is skipped, not completed, when no attempt exists yet", %{scope: scope} do
    task = %{
      id: "task-1",
      story_id: "4242",
      agent_id: "a-qa-subagent",
      requirement_name: "qa_complete"
    }

    assert {:ok, :skip, why} = QaStory.evaluate(scope, task),
           "a QA task owned by a sub-agent, with no attempt recorded, was answered " <>
             "with something other than :skip. `:valid` completes it -- which is " <>
             "7f79b855, the parent's stop discarding the sub-agent's run before it " <>
             "submitted -- and `:invalid` files demand-submit feedback against a " <>
             "parent that has no scenarios to report."

    assert why =~ "sub-agent", "the reason should name why it was left alone"
  end

  test "is completed once an attempt satisfies it", %{scope: scope} do
    # No attempt for this story, and no sub-agent owner: the ordinary path,
    # asserted so the skip above is known to be the guard firing rather than
    # evaluate/2 answering :skip for everything.
    task = %{id: "task-2", story_id: "4243", agent_id: nil, requirement_name: "qa_complete"}

    refute match?({:ok, :skip, _}, QaStory.evaluate(scope, task)),
           "evaluate/2 answers :skip even without a sub-agent owner, so the guard is " <>
             "not what produced the previous result"
  end
end
