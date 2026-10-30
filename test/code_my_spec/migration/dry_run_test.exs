defmodule CodeMySpec.Migration.DryRunTest do
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

  test "a legacy JSON export is counted and leaves the throwaway project untouched", %{
    scope: scope
  } do
    long = "As a user I want the full legacy story. " <> String.duplicate("More detail. ", 55)

    payload = %{
      "stories" => [
        %{"local_id" => 7, "title" => "Legacy story", "story" => long, "description" => long}
      ],
      "qa_attempts" => [
        %{
          "local_id" => Ecto.UUID.generate(),
          "story_local_id" => 7,
          "status" => "partial",
          "scenarios" => [
            %{"name" => "Login", "status" => "blocked", "observation" => "No fixture"}
          ],
          "issue_local_ids" => [],
          "submitted_at" => "2026-09-03T01:50:41Z"
        }
      ]
    }

    path = Path.join(CodeMySpec.TempFile.owned_dir("legacy_export"), "export.json")
    File.write!(path, Jason.encode!(payload))

    assert {:ok, %{status: :imported, rolled_back: true, refused: nil, counts: counts}} =
             Migration.dry_run_file(scope, path)

    assert counts.stories == 1
    assert counts.qa_attempts == 1
    assert counts.issues == 0
    assert {:ok, []} = Stories.list_project_stories(scope)
    assert Repo.all(QaAttempt) == []
  end

  test "a refused export reports its reason and persists nothing", %{scope: scope} do
    payload = %{
      "stories" => [
        %{"local_id" => 7, "title" => "", "story" => "As a user I want this so that that."}
      ]
    }

    assert {:ok, %{status: :refused, rolled_back: true, refused: reason}} =
             Migration.dry_run_project(scope, payload)

    assert is_binary(reason)
    assert reason != ""
    assert {:ok, []} = Stories.list_project_stories(scope)
  end
end
