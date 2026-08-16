defmodule CodeMySpec.Git.CLITest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.{UsersFixtures, IntegrationsFixtures}

  alias CodeMySpec.Git.CLI
  alias CodeMySpec.Users.Scope

  # ============================================================================
  # Fixtures
  # ============================================================================

  defp test_repo_url, do: "https://github.com/Code-My-Spec/test_phoenix_project.git"
  defp github_repo_url, do: "https://github.com/test-owner/test-repo.git"
  defp gitlab_repo_url, do: "https://gitlab.com/test-owner/test-repo.git"
  defp bitbucket_repo_url, do: "https://bitbucket.org/test-owner/test-repo.git"

  defp github_token, do: "ghp_test_token_#{:rand.uniform(100_000)}"

  defp temp_clone_path do
    base_path = System.tmp_dir!()
    unique_suffix = "git_cli_test_#{System.unique_integer([:positive])}"
    Path.join(base_path, unique_suffix)
  end

  defp scope_with_github_integration do
    user = user_fixture()
    token = github_token()
    _integration = github_integration_fixture(user, %{access_token: token})
    scope = %Scope{user: user}
    {scope, token}
  end

  defp scope_without_integration do
    user = user_fixture()
    %Scope{user: user}
  end

  defp cleanup_path(path), do: File.rm_rf(path)

  # ============================================================================
  # clone/3 - Integration Tests (with real GitHub repo)
  # ============================================================================

  # ============================================================================
  # clone/3 - Error Cases
  # ============================================================================

  describe "clone/3 - GitHub repositories" do
    test "returns error when GitHub integration not found" do
      scope = scope_without_integration()
      clone_path = temp_clone_path()

      result = CLI.clone(scope, github_repo_url(), clone_path)

      assert {:error, :not_connected} = result
      refute File.exists?(clone_path)
    end
  end

  describe "clone/3 - GitLab repositories" do
    test "returns error when GitLab integration not found" do
      scope = scope_without_integration()
      clone_path = temp_clone_path()

      result = CLI.clone(scope, gitlab_repo_url(), clone_path)

      assert {:error, :not_connected} = result
      refute File.exists?(clone_path)
    end
  end

  describe "clone/3 - URL validation errors" do
    test "returns error for invalid repository URL" do
      {scope, _token} = scope_with_github_integration()
      clone_path = temp_clone_path()

      result = CLI.clone(scope, "not-a-valid-url", clone_path)

      assert {:error, :invalid_url} = result
      refute File.exists?(clone_path)
    end

    test "returns error for SSH URL format" do
      {scope, _token} = scope_with_github_integration()
      clone_path = temp_clone_path()

      result = CLI.clone(scope, "git@github.com:owner/repo.git", clone_path)

      assert {:error, :invalid_url} = result
      refute File.exists?(clone_path)
    end

    test "returns error for HTTP (non-HTTPS) URL" do
      {scope, _token} = scope_with_github_integration()
      clone_path = temp_clone_path()

      result = CLI.clone(scope, "http://github.com/owner/repo.git", clone_path)

      assert {:error, :invalid_url} = result
      refute File.exists?(clone_path)
    end

    test "returns error for nil URL" do
      {scope, _token} = scope_with_github_integration()
      clone_path = temp_clone_path()

      result = CLI.clone(scope, nil, clone_path)

      assert {:error, :invalid_url} = result
      refute File.exists?(clone_path)
    end

    test "returns error for empty URL" do
      {scope, _token} = scope_with_github_integration()
      clone_path = temp_clone_path()

      result = CLI.clone(scope, "", clone_path)

      assert {:error, :invalid_url} = result
      refute File.exists?(clone_path)
    end
  end

  describe "clone/3 - unsupported providers" do
    test "returns error for Bitbucket URL when only GitHub integration exists" do
      {scope, _token} = scope_with_github_integration()
      clone_path = temp_clone_path()

      result = CLI.clone(scope, bitbucket_repo_url(), clone_path)

      assert {:error, :unsupported_provider} = result
      refute File.exists?(clone_path)
    end

    test "returns error for custom domain git hosting" do
      {scope, _token} = scope_with_github_integration()
      clone_path = temp_clone_path()

      result = CLI.clone(scope, "https://git.custom-domain.com/owner/repo.git", clone_path)

      assert {:error, :unsupported_provider} = result
      refute File.exists?(clone_path)
    end
  end

  describe "clone/3 - path validation" do
    @tag :integration
    test "returns error when clone path is not empty" do
      {scope, _token} = scope_with_github_integration()
      clone_path = temp_clone_path()

      File.mkdir_p!(clone_path)
      File.write!(Path.join(clone_path, "existing_file.txt"), "content")
      result = CLI.clone(scope, test_repo_url(), clone_path)
      assert {:error, _reason} = result
      cleanup_path(clone_path)
    end

    @tag :integration
    test "returns error when clone path parent directory doesn't exist" do
      {scope, _token} = scope_with_github_integration()
      clone_path = "/nonexistent/parent/directory/repo"

      result = CLI.clone(scope, test_repo_url(), clone_path)

      assert {:error, _reason} = result
    end
  end

  # ============================================================================
  # pull/2 - Integration Tests
  # ============================================================================

  describe "pull/2 - integration tests with real repository" do
    @tag :integration
    test "restores original remote URL after pull operation" do
      {scope, _token} = scope_with_github_integration()
      clone_path = temp_clone_path()

      on_exit(fn -> cleanup_path(clone_path) end)

      # Clone and pull
      {:ok, _path} = CLI.clone(scope, test_repo_url(), clone_path)
      _result = CLI.pull(scope, clone_path)

      # Verify remote URL doesn't contain token
      {remote_url, 0} = System.cmd("git", ["remote", "get-url", "origin"], cd: clone_path)
      remote_url = String.trim(remote_url)

      refute String.contains?(remote_url, "ghp_")
      refute String.contains?(remote_url, "@github.com")
    end
  end

  # ============================================================================
  # pull/2 - Error Cases
  # ============================================================================

  describe "pull/2 - integration errors" do
    test "returns error when integration not found" do
      scope = scope_without_integration()
      clone_path = temp_clone_path()

      on_exit(fn -> cleanup_path(clone_path) end)

      # Local `git init` is enough — pull's integration check fires before any network.
      File.mkdir_p!(clone_path)
      {_, 0} = System.cmd("git", ["init"], cd: clone_path)

      {_, 0} =
        System.cmd("git", ["remote", "add", "origin", "https://github.com/owner/repo.git"],
          cd: clone_path
        )

      result = CLI.pull(scope, clone_path)

      assert {:error, :not_connected} = result
    end
  end

  describe "pull/2 - path validation" do
    test "returns error when path doesn't exist" do
      {scope, _token} = scope_with_github_integration()

      result = CLI.pull(scope, "/nonexistent/path/to/repo")

      assert {:error, _reason} = result
    end

    test "returns error when path is not a git repository" do
      {scope, _token} = scope_with_github_integration()
      non_repo_path = temp_clone_path()

      File.mkdir_p!(non_repo_path)

      on_exit(fn -> cleanup_path(non_repo_path) end)

      result = CLI.pull(scope, non_repo_path)

      assert {:error, _reason} = result
    end

    test "returns error for nil path" do
      {scope, _token} = scope_with_github_integration()

      result = CLI.pull(scope, nil)

      assert {:error, :invalid_path} = result
    end

    test "returns error for empty path" do
      {scope, _token} = scope_with_github_integration()

      result = CLI.pull(scope, "")

      assert {:error, :invalid_path} = result
    end
  end

  # ============================================================================
  # Security Tests
  # ============================================================================

  describe "security - credential handling" do
    @tag :integration
    test "pull removes token from remote URL even on git command failure" do
      {scope, _token} = scope_with_github_integration()
      clone_path = temp_clone_path()

      on_exit(fn -> cleanup_path(clone_path) end)

      # Clone the repository
      {:ok, _path} = CLI.clone(scope, test_repo_url(), clone_path)

      # Create a conflict to force pull failure
      readme_path = Path.join(clone_path, "README.md")
      File.write!(readme_path, "# Conflicting change\n")
      System.cmd("git", ["add", "."], cd: clone_path)
      System.cmd("git", ["commit", "-m", "Local change"], cd: clone_path)

      # Attempt pull (may fail due to divergence)
      _result = CLI.pull(scope, clone_path)

      # Verify token was cleaned up from remote URL
      {remote_url, 0} = System.cmd("git", ["remote", "get-url", "origin"], cd: clone_path)
      remote_url = String.trim(remote_url)

      refute String.contains?(remote_url, "@github.com")
    end
  end

  # ============================================================================
  # Scope and Multi-tenancy Tests
  # ============================================================================

  describe "scope isolation" do
    test "user without integration cannot access repositories" do
      scope_without = scope_without_integration()
      clone_path = temp_clone_path()

      result = CLI.clone(scope_without, github_repo_url(), clone_path)

      assert {:error, :not_connected} = result
      refute File.exists?(clone_path)
    end
  end

  # ============================================================================
  # Property-Based Tests
  # ============================================================================

  describe "property-based tests" do
    test "clone fails predictably for invalid inputs" do
      {scope, _token} = scope_with_github_integration()
      clone_path = temp_clone_path()

      invalid_inputs = [
        nil,
        "",
        "not-a-url",
        "git@github.com:owner/repo.git",
        "http://github.com/owner/repo.git"
      ]

      for invalid_url <- invalid_inputs do
        result = CLI.clone(scope, invalid_url, clone_path)

        assert {:error, _reason} = result
        refute File.exists?(clone_path)
      end
    end

    test "pull fails predictably for invalid paths" do
      {scope, _token} = scope_with_github_integration()

      invalid_paths = [
        nil,
        "",
        "/nonexistent/path"
      ]

      for invalid_path <- invalid_paths do
        result = CLI.pull(scope, invalid_path)

        assert {:error, _reason} = result
      end
    end
  end
end
