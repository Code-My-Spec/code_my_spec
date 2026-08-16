defmodule CodeMySpec.Issues.IssuesRepositoryTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Issues.IssuesRepository

  import CodeMySpec.UsersFixtures

  defp create_issue(scope, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          title: "Test issue #{System.unique_integer([:positive])}",
          severity: :high,
          scope: :app,
          description: "Something is broken"
        },
        overrides
      )

    {:ok, issue} = IssuesRepository.create_issue(scope, attrs)
    issue
  end

  describe "list_issues/1" do
    test "returns all issues for the project" do
      scope = full_scope_fixture()
      issue = create_issue(scope)

      issues = IssuesRepository.list_issues(scope)

      assert length(issues) == 1
      assert hd(issues).id == issue.id
    end

    test "returns empty list when no issues exist" do
      scope = full_scope_fixture()

      assert IssuesRepository.list_issues(scope) == []
    end

    test "orders by severity (critical first) then newest first" do
      scope = full_scope_fixture()
      _low = create_issue(scope, %{severity: :low})
      _critical = create_issue(scope, %{severity: :critical})
      _medium = create_issue(scope, %{severity: :medium})

      issues = IssuesRepository.list_issues(scope)
      severities = Enum.map(issues, & &1.severity)

      assert severities == [:critical, :medium, :low]
    end

    test "excludes issues from other projects" do
      scope = full_scope_fixture()
      other_scope = full_scope_fixture()

      _my_issue = create_issue(scope)
      _other_issue = create_issue(other_scope)

      assert length(IssuesRepository.list_issues(scope)) == 1
      assert length(IssuesRepository.list_issues(other_scope)) == 1
    end
  end

  describe "list_by_status/2" do
    test "returns only issues with matching status" do
      scope = full_scope_fixture()
      _incoming = create_issue(scope, %{severity: :high})

      assert [_] = IssuesRepository.list_by_status(scope, :incoming)
      assert [] = IssuesRepository.list_by_status(scope, :accepted)
    end

    test "returns empty list when none match" do
      scope = full_scope_fixture()
      _incoming = create_issue(scope)

      assert IssuesRepository.list_by_status(scope, :resolved) == []
    end

    test "respects project scope" do
      scope = full_scope_fixture()
      other_scope = full_scope_fixture()

      _my_issue = create_issue(scope)
      _other_issue = create_issue(other_scope)

      assert length(IssuesRepository.list_by_status(scope, :incoming)) == 1
      assert length(IssuesRepository.list_by_status(other_scope, :incoming)) == 1
    end
  end

  describe "list_by_story/2" do
    test "returns issues for the given story" do
      scope = full_scope_fixture()
      _issue1 = create_issue(scope, %{story_id: 1})
      _issue2 = create_issue(scope, %{story_id: 2})

      assert [_] = IssuesRepository.list_by_story(scope, 1)
      assert [_] = IssuesRepository.list_by_story(scope, 2)
    end

    test "returns empty list when story has no issues" do
      scope = full_scope_fixture()

      assert IssuesRepository.list_by_story(scope, 99) == []
    end

    test "respects project scope" do
      scope = full_scope_fixture()
      other_scope = full_scope_fixture()

      _my_issue = create_issue(scope, %{story_id: 1})
      _other_issue = create_issue(other_scope, %{story_id: 1})

      assert length(IssuesRepository.list_by_story(scope, 1)) == 1
      assert length(IssuesRepository.list_by_story(other_scope, 1)) == 1
    end
  end

  describe "get_issue!/2" do
    test "returns issue when it exists" do
      scope = full_scope_fixture()
      issue = create_issue(scope)

      result = IssuesRepository.get_issue!(scope, issue.id)

      assert result.id == issue.id
    end

    test "raises when not found" do
      scope = full_scope_fixture()

      assert_raise Ecto.NoResultsError, fn ->
        IssuesRepository.get_issue!(scope, Ecto.UUID.generate())
      end
    end

    test "raises when issue is in different project" do
      scope = full_scope_fixture()
      other_scope = full_scope_fixture()
      other_issue = create_issue(other_scope)

      assert_raise Ecto.NoResultsError, fn ->
        IssuesRepository.get_issue!(scope, other_issue.id)
      end
    end
  end

  describe "create_issue/2" do
    test "creates issue with valid attrs" do
      scope = full_scope_fixture()

      attrs = %{
        title: "A new bug",
        severity: :medium,
        scope: :app,
        description: "Something went wrong"
      }

      assert {:ok, %Issue{} = issue} = IssuesRepository.create_issue(scope, attrs)
      assert issue.title == "A new bug"
      assert issue.severity == :medium
      assert issue.status == :incoming
    end

    test "sets project_id and account_id from scope" do
      scope = full_scope_fixture()

      attrs = %{
        title: "Scoped issue",
        severity: :low,
        description: "Test description"
      }

      assert {:ok, issue} = IssuesRepository.create_issue(scope, attrs)
      assert issue.project_id == scope.active_project.id
      assert issue.account_id == scope.active_account.id
    end

    test "returns error for invalid attrs" do
      scope = full_scope_fixture()

      assert {:error, changeset} = IssuesRepository.create_issue(scope, %{})
      assert errors_on(changeset).title
      assert errors_on(changeset).severity
      assert errors_on(changeset).description
    end
  end

  describe "upsert_issue/2" do
    test "creates issue when no conflict" do
      scope = full_scope_fixture()

      attrs = %{
        title: "Unique issue title",
        severity: :high,
        description: "Not a duplicate",
        story_id: 1
      }

      assert {:ok, %Issue{} = issue, :created} = IssuesRepository.upsert_issue(scope, attrs)
      assert issue.title == "Unique issue title"
      assert issue.id != nil
    end

    test "returns existing issue on duplicate title + story_id + project_id" do
      scope = full_scope_fixture()

      attrs = %{
        title: "Duplicate title",
        severity: :high,
        description: "First insert",
        story_id: 5
      }

      {:ok, original, :created} = IssuesRepository.upsert_issue(scope, attrs)

      duplicate_attrs = Map.put(attrs, :description, "Second insert")
      {:ok, returned, :existing} = IssuesRepository.upsert_issue(scope, duplicate_attrs)

      assert returned.id == original.id
    end

    test "does not overwrite existing issue data on conflict" do
      scope = full_scope_fixture()

      attrs = %{
        title: "Stable title",
        severity: :critical,
        description: "Original description",
        story_id: 7
      }

      {:ok, original, :created} = IssuesRepository.upsert_issue(scope, attrs)

      updated_attrs = Map.merge(attrs, %{severity: :low, description: "Overwritten description"})
      {:ok, returned, :existing} = IssuesRepository.upsert_issue(scope, updated_attrs)

      assert returned.id == original.id
      assert returned.severity == :critical
      assert returned.description == "Original description"
    end
  end

  describe "update_status/3" do
    test "updates status successfully" do
      scope = full_scope_fixture()
      issue = create_issue(scope)

      assert {:ok, updated} = IssuesRepository.update_status(issue, :accepted)
      assert updated.status == :accepted
    end

    test "sets resolution when provided" do
      scope = full_scope_fixture()
      issue = create_issue(scope)

      {:ok, accepted} = IssuesRepository.update_status(issue, :accepted)
      assert {:ok, resolved} = IssuesRepository.update_status(accepted, :resolved, "Fixed in PR #42")
      assert resolved.status == :resolved
      assert resolved.resolution == "Fixed in PR #42"
    end

    test "returns error for invalid status transition" do
      scope = full_scope_fixture()
      issue = create_issue(scope)

      assert {:error, changeset} = IssuesRepository.update_status(issue, :resolved, "Skipping steps")
      assert errors_on(changeset).status
    end
  end

  describe "count_by_status_and_min_severity/3" do
    test "counts issues at or above minimum severity" do
      scope = full_scope_fixture()
      _critical = create_issue(scope, %{severity: :critical})
      _high = create_issue(scope, %{severity: :high})
      _low = create_issue(scope, %{severity: :low})

      # :high min_severity should include :critical and :high (2 issues)
      assert IssuesRepository.count_by_status_and_min_severity(scope, :incoming, :high) == 2
    end

    test "returns 0 when no matching issues" do
      scope = full_scope_fixture()

      assert IssuesRepository.count_by_status_and_min_severity(scope, :incoming, :critical) == 0
    end

    test "respects project scope" do
      scope = full_scope_fixture()
      other_scope = full_scope_fixture()

      _my_issue = create_issue(scope, %{severity: :critical})
      _other_issue = create_issue(other_scope, %{severity: :critical})

      assert IssuesRepository.count_by_status_and_min_severity(scope, :incoming, :critical) == 1
      assert IssuesRepository.count_by_status_and_min_severity(other_scope, :incoming, :critical) == 1
    end
  end

  describe "delete_issue/1" do
    test "deletes issue successfully" do
      scope = full_scope_fixture()
      issue = create_issue(scope)

      assert {:ok, %Issue{}} = IssuesRepository.delete_issue(issue)
      assert IssuesRepository.list_issues(scope) == []
    end

    test "returns error for non-existent issue" do
      issue = %Issue{
        id: Ecto.UUID.generate(),
        __meta__: %Ecto.Schema.Metadata{state: :loaded, source: "issues"}
      }

      assert {:error, _} = IssuesRepository.delete_issue(issue)
    end
  end
end
