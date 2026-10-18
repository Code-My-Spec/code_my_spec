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
  alias CodeMySpec.Qa.QaAttempt
  alias CodeMySpec.Qa.Verdict
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

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
end
