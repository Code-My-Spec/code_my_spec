defmodule CodeMySpec.ContentSyncTest do
  use CodeMySpecTest.DataCase

  import CodeMySpec.{UsersFixtures, AccountsFixtures, ProjectsFixtures, ContentAdminFixtures}
  import Mox

  alias CodeMySpec.ContentSync
  alias CodeMySpec.ContentAdmin
  alias CodeMySpec.Users.Scope

  setup tags do
    # Only verify mocks for non-integration tests
    unless tags[:integration] do
      verify_on_exit!()
    end

    :ok
  end

  # ============================================================================
  # Fixtures - Scope Creation
  # ============================================================================

  defp scope_with_project(attrs \\ %{}) do
    user = user_fixture()
    account = account_fixture(%{name: "Test Account"})

    scope = %Scope{
      user: user,
      active_account: account,
      active_account_id: account.id,
      active_project_id: nil
    }

    default_project_attrs = %{
      name: "Test Project",
      docs_repo: "https://github.com/test/docs-repo.git"
    }

    project_attrs = Map.merge(default_project_attrs, attrs)
    project = project_fixture(scope, project_attrs)

    %Scope{
      user: user,
      active_account: account,
      active_account_id: account.id,
      active_project: project,
      active_project_id: project.id
    }
  end

  defp scope_without_project do
    user = user_fixture()
    account = account_fixture(%{name: "Test Account"})

    %Scope{
      user: user,
      active_account: account,
      active_account_id: account.id,
      active_project: nil,
      active_project_id: nil
    }
  end

  defp scope_without_docs_repo do
    scope_with_project(%{docs_repo: nil})
  end

  # ============================================================================
  # sync_to_content_admin/1 - Successful Sync Operations
  # ============================================================================

  describe "sync_to_content_admin/1 - successful git-based sync" do
    @tag :integration
    test "successfully clones repo and syncs content to ContentAdmin" do
      scope =
        scope_with_project(%{docs_repo: "https://github.com/johns10/test_content_repo.git"})

      assert {:ok, result} = ContentSync.sync_to_content_admin(scope)
      # test_content_repo has at least 4 valid files
      assert result.total_files >= 4
      assert result.successful >= 4
      assert result.errors >= 0
      assert is_integer(result.duration_ms)
      assert result.duration_ms >= 0

      # Verify ContentAdmin records were created in database
      content_admin = ContentAdmin.list_all_content(scope)
      assert length(content_admin) >= 4

      # Verify scoping
      Enum.each(content_admin, fn item ->
        assert item.account_id == scope.active_account_id
        assert item.project_id == scope.active_project_id
      end)
    end
  end

  describe "sync_to_content_admin/1 - scope validation" do
    test "returns error when scope has no active_project_id" do
      scope = scope_without_project()

      result = ContentSync.sync_to_content_admin(scope)
      assert match?({:error, _}, result)
    end

    test "returns error when project has no docs_repo configured" do
      scope = scope_without_docs_repo()

      assert {:error, :no_docs_repo} = ContentSync.sync_to_content_admin(scope)
    end

    test "returns error when project does not exist" do
      scope = scope_with_project()
      invalid_scope = %{scope | active_project_id: Ecto.UUID.generate()}

      assert {:error, :project_not_found} = ContentSync.sync_to_content_admin(invalid_scope)
    end

    test "returns error when scope account does not match project account" do
      scope1 = scope_with_project()
      scope2 = scope_with_project()

      # Try to access project from scope1 using scope2's account
      invalid_scope = %{scope2 | active_project_id: scope1.active_project_id}

      assert {:error, :project_not_found} = ContentSync.sync_to_content_admin(invalid_scope)
    end
  end

  describe "sync_to_content_admin/1 - temporary directory cleanup" do
    @tag :integration
    test "cleans up temporary directory after successful sync" do
      scope =
        scope_with_project(%{docs_repo: "https://github.com/johns10/test_content_repo.git"})

      assert {:ok, result} = ContentSync.sync_to_content_admin(scope)

      # Verify sync completed successfully
      assert result.total_files > 0
      assert result.successful > 0

      # Verify content was synced to database
      content_admin = ContentAdmin.list_all_content(scope)
      assert length(content_admin) > 0
    end
  end

  # ============================================================================
  # list_content_admin_errors/1 - Query Error ContentAdmin
  # ============================================================================

  describe "list_content_admin_errors/1 - query content admin with errors" do
    test "returns only content admin with error parse status" do
      scope = scope_with_project()

      # Create successful content admin
      _success =
        success_content_admin_fixture(scope, %{
          title: "Success Post",
          slug: "success-post"
        })

      # Create error content admin
      error =
        error_content_admin_fixture(scope, %{
          title: "Error Post",
          slug: "error-post",
          parse_errors: %{"error_type" => "metadata_missing", "message" => "Missing title"}
        })

      result = ContentSync.list_content_admin_errors(scope)
      assert length(result) == 1
      assert hd(result).id == error.id
      assert hd(result).parse_status == :error
    end

    test "returns empty list when no errors exist" do
      scope = scope_with_project()

      _success =
        success_content_admin_fixture(scope, %{
          title: "Success Post",
          slug: "success-post"
        })

      result = ContentSync.list_content_admin_errors(scope)
      assert result == []
    end

    test "returns multiple error content admin records" do
      scope = scope_with_project()

      for i <- 1..5 do
        error_content_admin_fixture(scope, %{
          title: "Error Post #{i}",
          slug: "error-post-#{i}"
        })
      end

      result = ContentSync.list_content_admin_errors(scope)
      assert length(result) == 5
      assert Enum.all?(result, &(&1.parse_status == :error))
    end

    test "scopes errors to project" do
      scope1 = scope_with_project()
      scope2 = scope_with_project()

      # Create error in project 1
      error1 =
        error_content_admin_fixture(scope1, %{
          title: "Error Post 1",
          slug: "error-post-1"
        })

      # Create error in project 2
      _error2 =
        error_content_admin_fixture(scope2, %{
          title: "Error Post 2",
          slug: "error-post-2"
        })

      result1 = ContentSync.list_content_admin_errors(scope1)
      assert length(result1) == 1
      assert hd(result1).id == error1.id

      result2 = ContentSync.list_content_admin_errors(scope2)
      assert length(result2) == 1
      refute hd(result2).id == error1.id
    end

    test "includes parse_errors details in result" do
      scope = scope_with_project()

      error_details = %{
        "error_type" => "metadata_validation",
        "message" => "Missing required field: title",
        "field" => "title"
      }

      error =
        error_content_admin_fixture(scope, %{
          slug: "error-post",
          parse_errors: error_details
        })

      [result] = ContentSync.list_content_admin_errors(scope)
      assert result.id == error.id
      assert result.parse_errors == error_details
      assert result.parse_errors["error_type"] == "metadata_validation"
      assert result.parse_errors["message"] == "Missing required field: title"
      assert result.parse_errors["field"] == "title"
    end
  end
end
