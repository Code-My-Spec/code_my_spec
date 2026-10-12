defmodule CodeMySpec.StoryReconcileTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.AcceptanceCriteriaFixtures
  import CodeMySpec.IssuesFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Qa
  alias CodeMySpec.Qa.QaAttempt
  alias CodeMySpec.QaFixtures
  alias CodeMySpec.Stories
  alias CodeMySpec.StoryReconcile
  alias CodeMySpec.WorkingCopies

  @head String.duplicate("a", 40)
  @reviewed String.duplicate("b", 40)

  setup do
    scope = full_scope_fixture()
    story = story_fixture(scope, %{criteria: []})
    %{scope: scope, story: story}
  end

  defp plan(scope, opts \\ []), do: StoryReconcile.plan(scope, [head: @head] ++ opts)

  defp reviewed!(scope, story) do
    {:ok, story} = Stories.set_qa_ready(scope, story, @reviewed)
    {:ok, attempt} = QaFixtures.passed_qa_attempt(scope, story_id: story.id)
    {story, attempt}
  end

  defp parked!(scope) do
    story = story_fixture(scope, %{criteria: [], ready_for_dev: false})
    criterion_fixture(scope, story)
    reviewed!(scope, story)
  end

  test "never creates certification from a historical pass or checkout HEAD", ctx do
    Repo.insert!(
      QaAttempt.changeset(%{
        story_id: ctx.story.id,
        status: :pass,
        scenarios: [%{name: "historical", status: :pass, observation: "legacy record"}],
        submitted_at: DateTime.utc_now()
      })
    )

    plan = plan(ctx.scope)
    assert {:ok, [], %{already: 0}} = plan.qa_ready
    assert :ok = StoryReconcile.carry_out(ctx.scope, plan)
    assert Stories.get_story!(ctx.scope, ctx.story.id).qa_ready_commit == nil
  end

  test "leaves an existing reviewed stamp at its exact revision", ctx do
    {story, _} = reviewed!(ctx.scope, ctx.story)
    assert {:ok, [], %{already: 1}} = plan(ctx.scope).qa_ready
    assert Stories.get_story!(ctx.scope, story.id).qa_ready_commit == @reviewed
  end

  test "planning writes nothing", ctx do
    {story, _} = reviewed!(ctx.scope, ctx.story)
    assert {:ok, [], %{already: 1}} = plan(ctx.scope).qa_ready
    assert Stories.get_story!(ctx.scope, story.id).qa_ready_at == story.qa_ready_at
  end

  test "un-park is skipped unless requested", %{scope: scope} do
    assert plan(scope).unpark == :skipped
  end

  test "un-parks with the exact reviewed stamp rather than HEAD", %{scope: scope} do
    {parked, _} = parked!(scope)
    plan = plan(scope, unpark: true)
    assert {:ok, [%{story: %{id: id}}], _} = plan.unpark
    assert id == parked.id
    assert {:ok, [%{after: @reviewed, source: :kept}], %{already: 0}} = plan.qa_ready
    assert :ok = StoryReconcile.carry_out(scope, plan)
    released = Stories.get_story!(scope, parked.id)
    assert released.ready_for_dev
    assert released.qa_ready_commit == @reviewed
    assert released.qa_ready_at == parked.qa_ready_at
    assert Qa.story_review_current?(scope, released.id)
  end

  test "preserves the specs-ready evidence while unparking", %{scope: scope} do
    {parked, _} = parked!(scope)
    at = ~U[2026-10-01 12:00:00.000000Z]
    {:ok, _} = Stories.set_specs_ready(scope, parked, true, at: at, commit: @reviewed)
    assert :ok = StoryReconcile.carry_out(scope, plan(scope, unpark: true))
    released = Stories.get_story!(scope, parked.id)
    assert released.ready_for_dev
    assert released.specs_ready
    assert released.specs_ready_commit == @reviewed
    assert released.specs_ready_at == at
  end

  test "does not release an unreviewed or failed story", %{scope: scope} do
    unreviewed = story_fixture(scope, %{criteria: [], ready_for_dev: false})
    criterion_fixture(scope, unreviewed)
    {_parked, attempt} = parked!(scope)
    Repo.update!(Ecto.Changeset.change(attempt, status: :fail))
    assert {:ok, [], _} = plan(scope, unpark: true).unpark
  end

  test "dry-run unpark preserves the existing stamp and parked status", %{scope: scope} do
    {parked, _} = parked!(scope)
    assert {:ok, [_], _} = plan(scope, unpark: true).unpark
    unchanged = Stories.get_story!(scope, parked.id)
    refute unchanged.ready_for_dev
    assert unchanged.qa_ready_commit == @reviewed
    assert unchanged.qa_ready_at == parked.qa_ready_at
  end

  test "an incoming issue prevents release without invalidating recorded QA", %{scope: scope} do
    {parked, _} = parked!(scope)
    issue_fixture(scope, %{story_id: parked.id, severity: :low})
    assert {:ok, [], _} = plan(scope, unpark: true).unpark
  end

  test "applying a stale plan cannot restore superseded certification", %{scope: scope} do
    {parked, _} = parked!(scope)
    plan = plan(scope, unpark: true)
    {:ok, _} = Stories.set_qa_ready(scope, parked, @head)
    assert {:error, {_, :story_reconcile_plan_stale}} = StoryReconcile.carry_out(scope, plan)
    unchanged = Stories.get_story!(scope, parked.id)
    refute unchanged.ready_for_dev
    assert unchanged.qa_ready_commit == @head
  end

  test "an issue arriving after planning prevents release", %{scope: scope} do
    {parked, _} = parked!(scope)
    plan = plan(scope, unpark: true)
    issue_fixture(scope, %{story_id: parked.id, severity: :low})
    assert {:error, {_, :story_reconcile_plan_stale}} = StoryReconcile.carry_out(scope, plan)
    refute Stories.get_story!(scope, parked.id).ready_for_dev
  end

  test "a new accepted unsubmitted issue makes the captured bag ineligible", %{scope: scope} do
    {parked, _} = parked!(scope)
    planned = plan(scope, unpark: true)
    issue_fixture(scope, %{story_id: parked.id, severity: :high, status: :accepted})

    assert {:ok, [], _} = plan(scope, unpark: true).unpark
    assert {:error, {_, :story_reconcile_plan_stale}} = StoryReconcile.carry_out(scope, planned)
    refute Stories.get_story!(scope, parked.id).ready_for_dev
  end

  test "binds the working copy registered at the root", %{scope: scope} do
    {:ok, copy} = WorkingCopies.fetch(scope.active_working_copy_id)
    root = Path.join(System.tmp_dir!(), "reconcile_#{System.unique_integer([:positive])}")
    WorkingCopies.report_root(copy, root)

    assert {:ok, %{active_working_copy_id: id}} =
             StoryReconcile.bind_checkout(%{scope | active_working_copy_id: nil}, root)

    assert id == copy.id
    assert {:error, message} = StoryReconcile.bind_checkout(scope, root <> "_elsewhere")
    assert message =~ "No working copy"
  end
end
