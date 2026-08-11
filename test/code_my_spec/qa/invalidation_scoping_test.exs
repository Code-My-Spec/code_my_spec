defmodule CodeMySpec.Qa.InvalidationScopingTest do
  @moduledoc """
  Invalidating a QA attempt is an audit action, and it must be someone's to take.

  `Invalidations.invalidate/3` takes a `%Scope{}` and used it only to stamp who
  invalidated. The attempt itself came from `Repo.get(QaAttempt, attempt_id)`,
  which authorises nothing — so an agent working one project could invalidate
  another project's attempt by id, and the invalidation would be recorded
  against them as though it were theirs. The docstring's "Pre-checks: the target
  attempt exists" was accurate, and was the whole of it.

  Same shape as `b3f08e21` in `InvitationRepository`: a function holding a scope
  and reading past it. Found by auditing for that shape rather than from a
  report, and it had no test of its own in either direction.

  `QaAttempts.by_project/2` already fails closed on a scope with no active
  project, which is why the fix routes through that module rather than joining
  again here.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.{QaFixtures, StoriesFixtures, UsersFixtures}

  alias CodeMySpec.Qa

  setup do
    mine = full_scope_fixture()
    theirs = full_scope_fixture()

    story = story_fixture(theirs)
    {:ok, attempt} = passed_qa_attempt(theirs, story_id: story.id)

    %{mine: mine, theirs: theirs, attempt: attempt}
  end

  test "another project's attempt cannot be invalidated", ctx do
    assert {:error, :attempt_not_found} =
             Qa.invalidate_qa_attempt(ctx.mine, ctx.attempt.id, "not mine to reject")
  end

  # Absent and not-yours answer the same way on purpose: telling them apart
  # confirms the id names a real attempt somewhere, which the caller has no
  # business learning.
  test "an id that names nothing answers the same way", ctx do
    assert {:error, :attempt_not_found} =
             Qa.invalidate_qa_attempt(ctx.mine, Ecto.UUID.generate(), "no such attempt")
  end

  test "the owning project can still invalidate", ctx do
    assert {:ok, invalidation} =
             Qa.invalidate_qa_attempt(ctx.theirs, ctx.attempt.id, "the pass was wrong")

    assert invalidation.qa_attempt_id == ctx.attempt.id
  end

  # The guard that makes the fix fail closed rather than open: a scope with no
  # active project matches nothing, instead of matching everything.
  test "a scope with no active project invalidates nothing", ctx do
    scope = %{ctx.theirs | active_project: nil, active_project_id: nil}

    assert {:error, :attempt_not_found} =
             Qa.invalidate_qa_attempt(scope, ctx.attempt.id, "no project on this scope")
  end
end
