defmodule CodeMySpec.Qa.ACrossStoryBlockerHoldsQaCompleteTest do
  @moduledoc """
  Issue 7fc8a61e: story 963's QA was blocked by issue c79fb8f9, then triage
  moved c79fb8f9 onto story 1013 because 1013 owned the defect. Nothing read
  the partial attempt's own citation of the issue once `issue.story_id` no
  longer matched, so 963 was offered for QA again with nothing changed.
  Story 1116, criterion 2196.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.AccountsFixtures
  import CodeMySpec.IssuesFixtures
  import CodeMySpec.ProjectsFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Issues
  alias CodeMySpec.Qa.Invalidations
  alias CodeMySpec.Qa.QaAttempt
  alias CodeMySpec.Qa.Verdict
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.Profiles
  alias CodeMySpec.Users.Scope

  def count_owner_query(_, _, _, {owner, counter}) when self() == owner do
    :counters.add(counter, 1, 1)
  end

  def count_owner_query(_, _, _, _), do: :ok

  setup do
    user = user_fixture()

    account =
      account_fixture(%{name: "Cross-story blocker #{System.unique_integer([:positive])}"})

    scope = %Scope{
      user: user,
      user_id: user.id,
      active_account: account,
      active_account_id: account.id
    }

    project = project_fixture(scope)
    scope = %Scope{scope | active_project: project, active_project_id: project.id}

    story = story_fixture(scope)
    blocker = issue_fixture(scope, %{status: :accepted, story_id: story.id})

    {:ok, _attempt} =
      %QaAttempt{}
      |> QaAttempt.changeset(%{
        story_id: story.id,
        status: :partial,
        scenarios: [%{name: "Provisioning", status: :partial, observation: "Dispatch unverified"}],
        issue_ids: [blocker.id],
        submitted_at: DateTime.utc_now()
      })
      |> Repo.insert()

    %{scope: scope, story: story, blocker: blocker}
  end

  test "an open blocker still owned by this story is left to the ordinary gate", %{
    scope: scope,
    story: story
  } do
    {satisfied?, details} = Verdict.complete_check(scope, story)

    refute satisfied?
    refute Map.has_key?(details, :waiting_on)
  end

  test "a framework issue QA cited is recorded but does not withhold qa_complete", %{
    scope: scope,
    story: story,
    blocker: blocker
  } do
    blocker |> Ecto.Changeset.change(story_id: nil, scope: :framework) |> Repo.update!()

    {_satisfied?, details} = Verdict.complete_check(scope, story)

    refute Map.get(details, :waiting_on) == "cross_story_issue_block"
  end

  test "re-triaging the blocker to another story still withholds qa_complete", %{
    scope: scope,
    story: story,
    blocker: blocker
  } do
    other = story_fixture(scope)
    {:ok, blocker} = Issues.update_issue(scope, blocker, %{story_id: other.id})

    {satisfied?, details} = Verdict.complete_check(scope, story)

    refute satisfied?
    assert details.waiting_on == "cross_story_issue_block"
    assert details.blocking_issue_id == blocker.id
  end

  test "a submitted cross-story blocker releases QA at the configured threshold", ctx do
    other = story_fixture(ctx.scope)

    ctx.blocker
    |> Ecto.Changeset.change(
      story_id: other.id,
      severity: :medium,
      story_submission_ref: Ecto.UUID.generate()
    )
    |> Repo.update!()

    {false, details} = Verdict.complete_check(ctx.scope, ctx.story)
    refute Map.has_key?(details, :waiting_on)

    {:ok, _} =
      CodeMySpec.Configurations.update(ctx.scope, %{fix_issues_min_severity: :high})

    {false, details} = Verdict.complete_check(ctx.scope, ctx.story)
    assert details.waiting_on == "cross_story_issue_block"
  end

  test "a dismissed cited blocker releases QA", ctx do
    {:ok, blocker} = Issues.update_issue(ctx.scope, ctx.blocker, %{story_id: nil})
    {false, held} = Verdict.complete_check(ctx.scope, ctx.story)
    assert held.waiting_on == "cross_story_issue_block"

    {:ok, _} = Issues.dismiss_issue(ctx.scope, blocker, "No longer applicable")
    {false, details} = Verdict.complete_check(ctx.scope, ctx.story)
    refute Map.has_key?(details, :waiting_on)
  end

  test "an invalidated attempt's citation no longer withholds QA", ctx do
    other = story_fixture(ctx.scope)
    {:ok, _blocker} = Issues.update_issue(ctx.scope, ctx.blocker, %{story_id: other.id})
    {false, held} = Verdict.complete_check(ctx.scope, ctx.story)
    assert held.waiting_on == "cross_story_issue_block"

    [attempt] = Repo.all(QaAttempt)
    {:ok, _} = Invalidations.invalidate(ctx.scope, attempt.id, "Taken before the build existed")

    {false, details} = Verdict.complete_check(ctx.scope, ctx.story)
    refute Map.has_key?(details, :waiting_on)
  end

  test "asking twice with nothing changed answers alike", %{
    scope: scope,
    story: story,
    blocker: blocker
  } do
    other = story_fixture(scope)
    {:ok, _blocker} = Issues.update_issue(scope, blocker, %{story_id: other.id})

    first = Verdict.complete_check(scope, story)
    second = Verdict.complete_check(scope, story)

    assert first == second
  end

  test "the blocker resolving releases qa_complete again", %{
    scope: scope,
    story: story,
    blocker: blocker
  } do
    other = story_fixture(scope)
    {:ok, blocker} = Issues.update_issue(scope, blocker, %{story_id: other.id})

    # `Issues.resolve_issue/3` itself refuses a story-owned issue with no
    # working-copy assignment ("must go through shared story QA and
    # promotion") — correct for the real surface, but this fixture only needs
    # the resolved *state* to check what reading it does, not to re-walk the
    # other story's own promotion pipeline (criterion 2101 already covers
    # that). Same direct-write style `QaFixtures` already uses for `story`.
    blocker
    |> Ecto.Changeset.change(status: :resolved, resolution: "Fixed on the owning story.")
    |> Repo.update!()

    {satisfied?, details} = Verdict.complete_check(scope, story)

    refute satisfied?
    refute Map.has_key?(details, :waiting_on)
  end

  test "the bulk QA profile preserves cross-story blocker verdicts", ctx do
    other = story_fixture(ctx.scope)
    {:ok, blocker} = Issues.update_issue(ctx.scope, ctx.blocker, %{story_id: other.id})
    profile = Profiles.load(ctx.scope, :qa)

    verdict_context = %{
      qa_latest_by_story: profile.latest_by_story,
      qa_submission_snapshots: profile.submission_snapshots,
      qa_issues_by_id: profile.issues_by_id,
      qa_issue_threshold: profile.issue_threshold
    }

    assert Map.has_key?(profile.issues_by_id, blocker.id)

    assert Verdict.complete_check(ctx.scope, ctx.story, verdict_context) ==
             Verdict.complete_check(ctx.scope, ctx.story)
  end

  test "bulk QA verdicts do not query once per cited issue", ctx do
    stories =
      for _ <- 1..12 do
        story = story_fixture(ctx.scope)

        %QaAttempt{}
        |> QaAttempt.changeset(%{
          story_id: story.id,
          status: :partial,
          scenarios: [%{name: "Blocked", status: :partial, observation: "Open issue"}],
          issue_ids: [ctx.blocker.id],
          submitted_at: DateTime.utc_now()
        })
        |> Repo.insert!()

        story
      end

    owner = self()
    counter = :counters.new(1, [])
    handler = {__MODULE__, owner, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:code_my_spec, :repo, :query],
        &__MODULE__.count_owner_query/4,
        {owner, counter}
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    profile = Profiles.load(ctx.scope, :qa)

    verdict_context = %{
      qa_latest_by_story: profile.latest_by_story,
      qa_submission_snapshots: profile.submission_snapshots,
      qa_issues_by_id: profile.issues_by_id,
      qa_issue_threshold: profile.issue_threshold
    }

    profile_queries = :counters.get(counter, 1)
    assert profile_queries < 20
    :counters.put(counter, 1, 0)

    for story <- stories do
      {false, details} =
        Verdict.complete_check(ctx.scope, story, Map.delete(verdict_context, :qa_issues_by_id))

      assert details.waiting_on == "cross_story_issue_block"
    end

    uncached_queries = :counters.get(counter, 1)
    assert uncached_queries >= length(stories)
    :counters.put(counter, 1, 0)

    for story <- stories do
      {false, details} = Verdict.complete_check(ctx.scope, story, verdict_context)
      assert details.waiting_on == "cross_story_issue_block"
    end

    assert :counters.get(counter, 1) == 0
  end
end
