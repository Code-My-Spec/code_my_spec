defmodule CodeMySpec.Migration.HistoryTravelsAsRecordedTest do
  @moduledoc """
  Moving this project to production (2026-10-27) was refused three times by
  records the source had kept for months: a story longer than the 600-character
  cap that came after it, a blocked QA scenario whose blocker issue the export
  dropped, and a passed attempt with a failed scenario recorded before that
  verdict rule existed. One refusal fails the whole one-transaction move.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Migration
  alias CodeMySpec.Qa.QaAttempt
  alias CodeMySpec.Stories

  setup do
    scope = full_scope_fixture()
    account = scope.active_account |> Ecto.Changeset.change(%{plan: :paid}) |> Repo.update!()
    {:ok, scope: %{scope | active_account: account}}
  end

  defp story(local_id, text \\ "As a user I want this so that that."),
    do: %{
      "local_id" => local_id,
      "title" => "Story #{local_id}",
      "story" => text,
      "description" => text
    }

  defp issue(local_id),
    do: %{
      "local_id" => local_id,
      "title" => "Analysis history unavailable",
      "description" => "No interface on this copy.",
      "severity" => "medium",
      "scope" => "qa",
      "status" => "accepted",
      "source" => "qa_agent"
    }

  defp attempt(status, scenarios, issue_local_ids),
    do: %{
      "local_id" => Ecto.UUID.generate(),
      "story_local_id" => 7,
      "status" => status,
      "scenarios" => scenarios,
      "issue_local_ids" => issue_local_ids,
      "submitted_at" => "2026-09-03T01:50:41Z"
    }

  test "a story over the cap lands with its full text in notes", %{scope: scope} do
    long =
      "As a bootstrap agent I need the setup tools registered. " <>
        String.duplicate("Mechanism detail. ", 60)

    assert {:ok, _} = Migration.import_project(scope, %{"stories" => [story(7, long)]})

    {:ok, [migrated]} = Stories.list_project_stories(scope)
    assert String.length(migrated.story) <= 600

    assert String.starts_with?(
             migrated.story,
             "As a bootstrap agent I need the setup tools registered."
           )

    assert String.ends_with?(migrated.story, "."), "cut at a sentence, not mid-word"
    assert migrated.notes =~ long
  end

  test "a blocked scenario keeps its blocker, rewritten to the issue's new id", %{scope: scope} do
    blocker = Ecto.UUID.generate()

    blocked = %{
      "name" => "Retention window change",
      "status" => "blocked",
      "observation" => "Not measured: no history interface.",
      "blocker_issue_local_id" => blocker
    }

    payload = %{
      "stories" => [story(7)],
      "issues" => [issue(blocker)],
      "qa_attempts" => [attempt("partial", [blocked], [blocker])]
    }

    assert {:ok, %{qa_attempts: 1}} = Migration.import_project(scope, payload)

    [%QaAttempt{scenarios: [scenario], issue_ids: [issue_id]}] = Repo.all(QaAttempt)
    assert scenario.blocker_issue_id == issue_id
    refute issue_id == blocker
  end

  # The legacy desktop app exports scenarios as they were before blockers
  # travelled: name, status and observation only, a blocked one naming nothing.
  test "a legacy payload's blocked scenario with no blocker still travels", %{scope: scope} do
    legacy = %{
      "name" => "Fixture login",
      "status" => "blocked",
      "observation" => "No fixture account."
    }

    payload = %{"stories" => [story(7)], "qa_attempts" => [attempt("partial", [legacy], [])]}

    assert {:ok, %{qa_attempts: 1}} = Migration.import_project(scope, payload)

    [%QaAttempt{scenarios: [scenario]}] = Repo.all(QaAttempt)
    assert scenario.status == :blocked
    assert scenario.blocker_issue_id == nil
  end

  test "a passed attempt recorded with a failed scenario still travels", %{scope: scope} do
    failed = %{
      "name" => "Turn-end run races the write",
      "status" => "fail",
      "observation" => "One run late."
    }

    payload = %{"stories" => [story(7)], "qa_attempts" => [attempt("pass", [failed], [])]}

    assert {:ok, %{qa_attempts: 1}} = Migration.import_project(scope, payload)
    assert [%QaAttempt{status: :pass}] = Repo.all(QaAttempt)
  end
end
