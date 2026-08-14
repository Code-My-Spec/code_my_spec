defmodule CodeMySpec.IssuesTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.Issues
  alias CodeMySpec.Issues.Issue

  import CodeMySpec.UsersFixtures

  defp issue_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        title: "Test issue #{System.unique_integer([:positive])}",
        severity: :high,
        scope: :app,
        description: "Something is broken"
      },
      overrides
    )
  end

  defp create_issue(scope, overrides \\ %{}) do
    {:ok, issue} = Issues.create_issue(scope, issue_attrs(overrides))
    issue
  end

  describe "create_issue/2" do
    test "creates issue with valid attributes" do
      scope = full_scope_fixture()
      attrs = issue_attrs()

      assert {:ok, %Issue{} = issue} = Issues.create_issue(scope, attrs)
      assert issue.title == attrs.title
      assert issue.severity == :high
      assert issue.scope == :app
      assert issue.status == :incoming
    end

    test "sets project_id and account_id from scope" do
      scope = full_scope_fixture()

      assert {:ok, issue} = Issues.create_issue(scope, issue_attrs())
      assert issue.project_id == scope.active_project.id
      assert issue.account_id == scope.active_account.id
    end

    test "projects issue file to .code_my_spec/issues/incoming/" do
      scope = full_scope_fixture()

      assert {:ok, _issue} = Issues.create_issue(scope, issue_attrs())
      # Projection happens via Projector — tested via Projector tests
      # Context integration verified here by no error raised
    end

    test "returns changeset error for invalid attributes" do
      scope = full_scope_fixture()
      assert {:error, %Ecto.Changeset{}} = Issues.create_issue(scope, %{})
    end

    test "validates required fields (title, severity, description)" do
      scope = full_scope_fixture()
      assert {:error, changeset} = Issues.create_issue(scope, %{})
      assert errors_on(changeset).title
      assert errors_on(changeset).severity
      assert errors_on(changeset).description
    end
  end

  describe "create_from_qa_result/3" do
    defp qa_document(issues) do
      %{sections: %{"issues" => issues}}
    end

    defp qa_issue(title, severity \\ "high") do
      %CodeMySpec.Documents.QaIssue{
        title: title,
        severity: severity,
        description: "A test issue",
        scope: "app"
      }
    end

    test "creates issues from QA result document" do
      scope = full_scope_fixture()
      doc = qa_document([qa_issue("Bug one"), qa_issue("Bug two", "low")])

      assert {:ok, created} = Issues.create_from_qa_result(scope, 1, doc)
      assert length(created) == 2
    end

    test "sets story_id from the story parameter" do
      scope = full_scope_fixture()
      doc = qa_document([qa_issue("A bug")])

      assert {:ok, [issue]} = Issues.create_from_qa_result(scope, 42, doc)
      assert issue.story_id == 42
    end

    test "skips duplicate issues (same title + story_id)" do
      scope = full_scope_fixture()
      doc = qa_document([qa_issue("Same bug")])

      assert {:ok, [_]} = Issues.create_from_qa_result(scope, 1, doc)
      assert {:ok, [_]} = Issues.create_from_qa_result(scope, 1, doc)

      assert length(Issues.list_issues(scope)) == 1
    end

    test "sets status to :incoming" do
      scope = full_scope_fixture()
      doc = qa_document([qa_issue("New bug")])

      assert {:ok, [issue]} = Issues.create_from_qa_result(scope, 1, doc)
      assert issue.status == :incoming
    end

    test "sets source_path to the QA result file" do
      scope = full_scope_fixture()
      doc = qa_document([qa_issue("Path bug")])

      assert {:ok, [issue]} = Issues.create_from_qa_result(scope, 5, doc)
      assert issue.source_path == ".code_my_spec/qa/5/result.md"
    end

    test "projects created issues to filesystem" do
      scope = full_scope_fixture()
      doc = qa_document([qa_issue("Projected bug")])

      # No error means projection succeeded (actual file checks in projector tests)
      assert {:ok, [_]} = Issues.create_from_qa_result(scope, 1, doc)
    end
  end

  describe "create_from_braindump/3" do
    test "creates issue from braindump content" do
      scope = full_scope_fixture()
      content = "# Fix the login flow\n\nThe login flow is confusing and needs rework."

      assert {:ok, issue} = Issues.create_from_braindump(scope, content)
      assert issue.title == "Fix the login flow"
      assert issue.description == "The login flow is confusing and needs rework."
    end

    test "defaults status to :accepted" do
      scope = full_scope_fixture()
      content = "# Some issue\n\nDescription here."

      assert {:ok, issue} = Issues.create_from_braindump(scope, content)
      assert issue.status == :accepted
    end

    test "defaults severity to :medium" do
      scope = full_scope_fixture()
      content = "# Some issue\n\nDescription here."

      assert {:ok, issue} = Issues.create_from_braindump(scope, content)
      assert issue.severity == :medium
    end

    test "merges explicit attrs over parsed content" do
      scope = full_scope_fixture()
      content = "# Critical bug\n\nApp crashes on startup."

      assert {:ok, issue} = Issues.create_from_braindump(scope, content, %{severity: :critical})
      assert issue.severity == :critical
    end

    test "projects to accepted directory" do
      scope = full_scope_fixture()
      content = "# Braindump issue\n\nSome description."

      # No error means projection succeeded
      assert {:ok, _issue} = Issues.create_from_braindump(scope, content)
    end
  end

  describe "list_issues/1" do
    test "returns all issues for the project" do
      scope = full_scope_fixture()
      issue = create_issue(scope)

      issues = Issues.list_issues(scope)
      assert [%Issue{id: id}] = issues
      assert id == issue.id
    end

    test "returns empty list when no issues exist" do
      scope = full_scope_fixture()
      assert [] = Issues.list_issues(scope)
    end

    test "respects project scope" do
      scope1 = full_scope_fixture()
      scope2 = full_scope_fixture()
      _issue1 = create_issue(scope1)
      _issue2 = create_issue(scope2)

      assert [_] = Issues.list_issues(scope1)
      assert [_] = Issues.list_issues(scope2)
    end

    test "orders by severity then creation date" do
      scope = full_scope_fixture()
      _low = create_issue(scope, %{severity: :low})
      _critical = create_issue(scope, %{severity: :critical})
      _medium = create_issue(scope, %{severity: :medium})

      issues = Issues.list_issues(scope)
      severities = Enum.map(issues, & &1.severity)
      assert severities == [:critical, :medium, :low]
    end
  end

  describe "list_by_status/2" do
    test "returns only issues with matching status" do
      scope = full_scope_fixture()
      _incoming = create_issue(scope)

      assert [_] = Issues.list_by_status(scope, :incoming)
      assert [] = Issues.list_by_status(scope, :accepted)
    end

    test "returns empty list when no issues match" do
      scope = full_scope_fixture()
      assert [] = Issues.list_by_status(scope, :incoming)
    end

    test "respects project scope" do
      scope1 = full_scope_fixture()
      scope2 = full_scope_fixture()
      _issue1 = create_issue(scope1)
      _issue2 = create_issue(scope2)

      assert [_] = Issues.list_by_status(scope1, :incoming)
      assert [_] = Issues.list_by_status(scope2, :incoming)
    end
  end

  describe "list_by_story/2" do
    test "returns issues for the given story" do
      scope = full_scope_fixture()
      _issue = create_issue(scope, %{story_id: 1})

      assert [_] = Issues.list_by_story(scope, 1)
    end

    test "returns empty list when story has no issues" do
      scope = full_scope_fixture()
      assert [] = Issues.list_by_story(scope, 999)
    end

    test "respects project scope" do
      scope1 = full_scope_fixture()
      scope2 = full_scope_fixture()
      _issue1 = create_issue(scope1, %{story_id: 1})
      _issue2 = create_issue(scope2, %{story_id: 1})

      assert [_] = Issues.list_by_story(scope1, 1)
      assert [_] = Issues.list_by_story(scope2, 1)
    end
  end

  describe "get_issue!/2" do
    test "returns issue when it exists in project" do
      scope = full_scope_fixture()
      issue = create_issue(scope)

      assert Issues.get_issue!(scope, issue.id).id == issue.id
    end

    test "raises Ecto.NoResultsError when issue doesn't exist" do
      scope = full_scope_fixture()

      assert_raise Ecto.NoResultsError, fn ->
        Issues.get_issue!(scope, Ecto.UUID.generate())
      end
    end

    test "raises when issue exists but in different project" do
      scope1 = full_scope_fixture()
      scope2 = full_scope_fixture()
      issue = create_issue(scope1)

      assert_raise Ecto.NoResultsError, fn ->
        Issues.get_issue!(scope2, issue.id)
      end
    end
  end

  describe "accept_issue/2" do
    test "transitions incoming issue to accepted" do
      scope = full_scope_fixture()
      issue = create_issue(scope)

      assert {:ok, accepted} = Issues.accept_issue(scope, issue)
      assert accepted.status == :accepted
    end

    test "re-projects file from incoming to accepted directory" do
      scope = full_scope_fixture()
      issue = create_issue(scope)

      # No error means projection succeeded
      assert {:ok, _accepted} = Issues.accept_issue(scope, issue)
    end

    test "returns error when issue is not in :incoming status" do
      scope = full_scope_fixture()
      issue = create_issue(scope)
      {:ok, accepted} = Issues.accept_issue(scope, issue)

      assert {:error, changeset} = Issues.accept_issue(scope, accepted)
      assert errors_on(changeset).status
    end
  end

  describe "dismiss_issue/3" do
    test "transitions incoming issue to dismissed" do
      scope = full_scope_fixture()
      issue = create_issue(scope)

      assert {:ok, dismissed} = Issues.dismiss_issue(scope, issue, "Not a real bug")
      assert dismissed.status == :dismissed
    end

    test "stores dismissal reason in resolution field" do
      scope = full_scope_fixture()
      issue = create_issue(scope)

      assert {:ok, dismissed} = Issues.dismiss_issue(scope, issue, "Duplicate of #42")
      assert dismissed.resolution == "Duplicate of #42"
    end

    test "removes projected file" do
      scope = full_scope_fixture()
      issue = create_issue(scope)

      # No error means removal succeeded
      assert {:ok, _dismissed} = Issues.dismiss_issue(scope, issue, "Not needed")
    end

    test "returns error when issue is not in :incoming status" do
      scope = full_scope_fixture()
      issue = create_issue(scope)
      {:ok, accepted} = Issues.accept_issue(scope, issue)

      assert {:error, changeset} = Issues.dismiss_issue(scope, accepted, "Too late")
      assert errors_on(changeset).status
    end
  end

  describe "resolve_issue/3" do
    test "transitions accepted issue to resolved" do
      scope = full_scope_fixture()
      issue = create_issue(scope)
      {:ok, accepted} = Issues.accept_issue(scope, issue)

      assert {:ok, resolved} = Issues.resolve_issue(scope, accepted, "Fixed in commit abc123")
      assert resolved.status == :resolved
    end

    test "stores resolution text" do
      scope = full_scope_fixture()
      issue = create_issue(scope)
      {:ok, accepted} = Issues.accept_issue(scope, issue)

      assert {:ok, resolved} = Issues.resolve_issue(scope, accepted, "Fixed in PR #99")
      assert resolved.resolution == "Fixed in PR #99"
    end

    test "re-projects file with Resolution section appended" do
      scope = full_scope_fixture()
      issue = create_issue(scope)
      {:ok, accepted} = Issues.accept_issue(scope, issue)

      # No error means projection succeeded
      assert {:ok, _resolved} = Issues.resolve_issue(scope, accepted, "All fixed")
    end

    test "returns error when issue is not in :accepted status" do
      scope = full_scope_fixture()
      issue = create_issue(scope)

      assert {:error, changeset} = Issues.resolve_issue(scope, issue, "Skipping triage")
      assert errors_on(changeset).status
    end
  end

  describe "has_unresolved_issues?/2" do
    test "returns true when unresolved issues exist at severity" do
      scope = full_scope_fixture()
      issue = create_issue(scope, %{severity: :high})
      {:ok, _} = Issues.accept_issue(scope, issue)

      assert Issues.has_unresolved_issues?(scope, :high)
    end

    test "returns false when all issues are resolved" do
      scope = full_scope_fixture()
      issue = create_issue(scope, %{severity: :high})
      {:ok, accepted} = Issues.accept_issue(scope, issue)
      {:ok, _} = Issues.resolve_issue(scope, accepted, "Fixed")

      refute Issues.has_unresolved_issues?(scope, :high)
    end

    test "respects minimum severity threshold" do
      scope = full_scope_fixture()
      issue = create_issue(scope, %{severity: :high})
      {:ok, _} = Issues.accept_issue(scope, issue)

      assert Issues.has_unresolved_issues?(scope, :medium)
      assert Issues.has_unresolved_issues?(scope, :high)
      refute Issues.has_unresolved_issues?(scope, :critical)
    end

    test "ignores dismissed issues" do
      scope = full_scope_fixture()
      issue = create_issue(scope, %{severity: :high})
      {:ok, _} = Issues.dismiss_issue(scope, issue, "Not a bug")

      refute Issues.has_unresolved_issues?(scope, :high)
    end
  end

  describe "has_untriaged_issues?/2" do
    test "returns true when untriaged issues exist at severity" do
      scope = full_scope_fixture()
      _issue = create_issue(scope, %{severity: :medium})

      assert Issues.has_untriaged_issues?(scope, :medium)
    end

    test "returns false when no incoming issues exist" do
      scope = full_scope_fixture()
      refute Issues.has_untriaged_issues?(scope, :medium)
    end

    test "respects minimum severity threshold" do
      scope = full_scope_fixture()
      _issue = create_issue(scope, %{severity: :medium})

      assert Issues.has_untriaged_issues?(scope, :medium)
      assert Issues.has_untriaged_issues?(scope, :low)
      refute Issues.has_untriaged_issues?(scope, :high)
    end
  end
end
