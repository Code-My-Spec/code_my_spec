defmodule CodeMySpec.Validation.TaskEvaluatorTest do
  @moduledoc """
  What a stop says when a checker could not look.

  The stop hook returned exactly `Error: :no_environment` and nothing else — no
  task, no requirement, no working copy, no action. The turn was blocked with
  nothing in the message to act on, which is the whole of the defect: the atom
  itself is the intended reply from `Environments` when a scope has no working
  copy, and under a light harness that is the steady state rather than an edge
  case.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Validation.TaskEvaluator

  @harness "d1c8f8f5-13e5-4827-865e-55a081f988a6"

  defp feedback(scope \\ %Scope{active_harness_id: @harness}) do
    TaskEvaluator.unobservable_feedback(%{id: 4321}, "QaIntegrationPlan", scope, :no_environment)
  end

  test "it says which checker, which task and which working copy" do
    text = feedback()

    assert text =~ "QaIntegrationPlan"
    assert text =~ "4321"
    assert text =~ @harness
  end

  # The distinction the whole message exists to draw. An agent that reads this
  # as a failed requirement rewrites work that is already done — the reported
  # incident was six specs that existed.
  test "it says this is not the requirement failing" do
    text = feedback()

    assert text =~ "not a requirement failure"
    assert text =~ "do not rewrite the work"
  end

  test "it says where the bug is and how to report it" do
    text = feedback()

    assert text =~ "framework bug"
    assert text =~ "create_issue"

    assert text =~ "Files",
           "the fix is for the checker to read the harness's file report; naming it " <>
             "is what turns this from a dead end into a bug report"
  end

  test "a scope naming no working copy says so rather than printing nothing" do
    text = feedback(%Scope{active_harness_id: nil})

    assert text =~ "no harness on the scope"
  end
end
