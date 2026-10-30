defmodule CodeMySpec.Qa.NothingNewSinceTheLastAttemptTest do
  @moduledoc """
  Issue 9180ef3d: story 1146's `qa_complete` was pushed three times in three
  minutes at one commit, and each time QA re-checked the same state and
  submitted the same partial, citing an environment issue that had not moved.
  Pushing it again is only worth it once something has: a new certification,
  or a change to an issue the last attempt cited.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.IssuesFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Qa.Invalidation
  alias CodeMySpec.Qa.QaAttempt
  alias CodeMySpec.Qa.Verdict
  alias CodeMySpec.Repo

  setup do
    scope = full_scope_fixture()

    story =
      scope
      |> story_fixture()
      |> Ecto.Changeset.change(qa_ready_commit: "ce65175b5", qa_ready_at: DateTime.utc_now())
      |> Repo.update!()

    blocker = issue_fixture(scope, %{status: :accepted, scope: :qa})
    %{scope: scope, story: story, blocker: blocker}
  end

  defp attempt(story, status, issue_ids, reviewed_commit \\ "ce65175b5") do
    %QaAttempt{}
    |> QaAttempt.changeset(%{
      story_id: story.id,
      status: status,
      scenarios: [%{name: "Readiness", status: :partial, observation: "No connected harness"}],
      issue_ids: issue_ids,
      reviewed_commit: reviewed_commit,
      review_started_at: DateTime.utc_now(),
      submitted_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  test "a partial at the certified commit, citing an issue that has not moved, is a repeat",
       %{scope: scope, story: story, blocker: blocker} do
    attempt(story, :partial, [blocker.id])
    assert Verdict.nothing_new_since_last_attempt?(scope, story.id)
  end

  test "a cited issue changing since is something new", ctx do
    attempt(ctx.story, :partial, [ctx.blocker.id])

    ctx.blocker
    |> Ecto.Changeset.change(updated_at: DateTime.add(DateTime.utc_now(), 5, :second))
    |> Repo.update!()

    refute Verdict.nothing_new_since_last_attempt?(ctx.scope, ctx.story.id)
  end

  test "a new certification is something new", ctx do
    attempt(ctx.story, :partial, [ctx.blocker.id], "an-older-commit")
    refute Verdict.nothing_new_since_last_attempt?(ctx.scope, ctx.story.id)
  end

  test "a pass, or an invalidated attempt, is not held", ctx do
    attempt(ctx.story, :pass, [])
    refute Verdict.nothing_new_since_last_attempt?(ctx.scope, ctx.story.id)

    partial = attempt(ctx.story, :partial, [ctx.blocker.id])
    assert Verdict.nothing_new_since_last_attempt?(ctx.scope, ctx.story.id)

    %Invalidation{}
    |> Invalidation.changeset(%{
      qa_attempt_id: partial.id,
      reason: "harness restarted mid-run",
      invalidated_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    refute Verdict.nothing_new_since_last_attempt?(ctx.scope, ctx.story.id)
  end
end
