defmodule CodeMySpec.ContentSync.GitSyncTest do
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.{UsersFixtures, AccountsFixtures, ProjectsFixtures, IntegrationsFixtures}
  import Mox

  alias CodeMySpec.ContentSync.GitSync
  alias CodeMySpec.Users.Scope

  setup :verify_on_exit!

  # ============================================================================
  # Fixtures
  # ============================================================================

  defp scope_with_project(project_attrs \\ %{}) do
    user = user_fixture()
    account = account_fixture(%{name: "Test Account"})

    scope = %Scope{
      user: user,
      active_account: account,
      active_account_id: account.id,
      active_project_id: nil
    }

    default_attrs = %{
      name: "Test Project",
      docs_repo: "https://github.com/Code-My-Spec/test_phoenix_project.git"
    }

    project = project_fixture(scope, Map.merge(default_attrs, project_attrs))

    %Scope{
      user: user,
      active_account: account,
      active_account_id: account.id,
      active_project: project,
      active_project_id: project.id
    }
  end

  defp scope_without_active_project do
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

  # ============================================================================
  # Unit Tests (Mocked)
  # ============================================================================

  describe "clone_to_temp/1 - success cases" do
    test "successfully clones repository to temporary directory" do
      scope = scope_with_project()

      assert {:ok, temp_path} = GitSync.clone_to_temp(scope)
      assert is_binary(temp_path)

      # Cleanup
      File.rm_rf!(temp_path)
    end

    test "returns absolute path to temporary directory" do
      scope = scope_with_project()

      assert {:ok, temp_path} = GitSync.clone_to_temp(scope)
      assert is_binary(temp_path)
      assert String.starts_with?(temp_path, System.tmp_dir!())

      # Cleanup
      File.rm_rf!(temp_path)
    end

    test "trims whitespace from docs_repo URL" do
      scope =
        scope_with_project(%{
          docs_repo: "  https://github.com/Code-My-Spec/test_phoenix_project.git  "
        })

      assert {:ok, temp_path} = GitSync.clone_to_temp(scope)
      assert is_binary(temp_path)

      # Cleanup
      File.rm_rf!(temp_path)
    end
  end

  describe "clone_to_temp/1 - scope validation errors" do
    test "returns error when scope has no active_project_id" do
      scope = scope_without_active_project()

      assert {:error, :project_not_found} = GitSync.clone_to_temp(scope)
    end

    test "returns error when project does not exist" do
      scope = %Scope{
        user: user_fixture(),
        active_account_id: account_fixture().id,
        active_project_id: Ecto.UUID.generate()
      }

      assert {:error, :not_found} = GitSync.clone_to_temp(scope)
    end

    test "returns error when active_project_id is nil" do
      scope = %Scope{
        user: user_fixture(),
        active_account_id: 1,
        active_project_id: nil
      }

      assert {:error, :project_not_found} = GitSync.clone_to_temp(scope)
    end
  end

  describe "clone_to_temp/1 - project configuration errors" do
    test "returns error when project has no docs_repo configured" do
      scope = scope_with_project(%{docs_repo: nil})

      assert {:error, :no_docs_repo} = GitSync.clone_to_temp(scope)
    end

    test "returns error when project docs_repo is empty string" do
      scope = scope_with_project(%{docs_repo: ""})

      assert {:error, :no_docs_repo} = GitSync.clone_to_temp(scope)
    end

    test "returns error when project docs_repo is whitespace only" do
      scope = scope_with_project(%{docs_repo: "   "})

      assert {:error, :no_docs_repo} = GitSync.clone_to_temp(scope)
    end
  end

  describe "clone_to_temp/1 - Git errors" do
    setup do
      # Use MockGit for error case testing
      original = Application.get_env(:code_my_spec, :git_impl_module)
      Application.put_env(:code_my_spec, :git_impl_module, CodeMySpec.MockGit)

      on_exit(fn ->
        Application.put_env(:code_my_spec, :git_impl_module, original)
      end)

      :ok
    end

    test "returns error when git integration is not connected" do
      scope = scope_with_project()

      expect(CodeMySpec.MockGit, :clone, fn _scope, _url, _path ->
        {:error, :not_connected}
      end)

      assert {:error, :not_connected} = GitSync.clone_to_temp(scope)
    end

    test "returns error for invalid URL format" do
      scope = scope_with_project()

      expect(CodeMySpec.MockGit, :clone, fn _scope, _url, _path ->
        {:error, :invalid_url}
      end)

      assert {:error, :invalid_url} = GitSync.clone_to_temp(scope)
    end

    test "returns error for unsupported provider" do
      scope = scope_with_project()

      expect(CodeMySpec.MockGit, :clone, fn _scope, _url, _path ->
        {:error, :unsupported_provider}
      end)

      assert {:error, :unsupported_provider} = GitSync.clone_to_temp(scope)
    end

    test "propagates git clone errors" do
      scope = scope_with_project()

      expect(CodeMySpec.MockGit, :clone, fn _scope, _url, _path ->
        {:error, "git clone failed"}
      end)

      assert {:error, "git clone failed"} = GitSync.clone_to_temp(scope)
    end
  end

  describe "clone_to_temp/1 - multiple clones" do
    test "each clone creates unique temporary directory" do
      scope = scope_with_project()

      {:ok, temp_path1} = GitSync.clone_to_temp(scope)
      {:ok, temp_path2} = GitSync.clone_to_temp(scope)
      {:ok, temp_path3} = GitSync.clone_to_temp(scope)

      assert temp_path1 != temp_path2
      assert temp_path2 != temp_path3
      assert temp_path1 != temp_path3

      # Cleanup
      File.rm_rf!(temp_path1)
      File.rm_rf!(temp_path2)
      File.rm_rf!(temp_path3)
    end
  end

  # ============================================================================
  # Integration Tests (Real Git Operations)
  # ============================================================================

  describe "clone_to_temp/1 - integration test" do
    setup do
      # Use real Git.CLI for integration tests
      Application.put_env(:code_my_spec, :git_impl_module, CodeMySpec.Git.CLI)

      on_exit(fn ->
        Application.put_env(:code_my_spec, :git_impl_module, CodeMySpec.Support.TestAdapter)
      end)

      :ok
    end

    @tag :integration
    test "successfully clones real repository from GitHub" do
      user = user_fixture()
      account = account_fixture(%{name: "Test Account"})
      token = "ghp_test_token_#{:rand.uniform(100_000)}"
      _integration = github_integration_fixture(user, %{access_token: token})

      scope = %Scope{
        user: user,
        active_account: account,
        active_account_id: account.id,
        active_project_id: nil
      }

      project =
        project_fixture(scope, %{
          name: "Test Project",
          docs_repo: "https://github.com/Code-My-Spec/test_phoenix_project.git"
        })

      scope = %{scope | active_project: project, active_project_id: project.id}

      assert {:ok, temp_path} = GitSync.clone_to_temp(scope)
      assert is_binary(temp_path)
      assert File.exists?(temp_path)
      assert File.exists?(Path.join(temp_path, "mix.exs"))

      # Cleanup
      File.rm_rf!(temp_path)
    end
  end
end
