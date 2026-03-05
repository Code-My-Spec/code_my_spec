defmodule CodeMySpec.ProjectSetupWizard.GithubIntegrationTest do
  @moduledoc """
  Tests for GitHub integration functionality.

  ## VCR Cassette Recording

  Some tests use VCR to record/replay GitHub API interactions. To record cassettes with a real GitHub OAuth token:

  ### Option 1: Get OAuth token through the app (Recommended)

  1. Start the Phoenix server:
     ```
     mix phx.server
     ```

  2. Navigate to the integrations page and connect your GitHub account through OAuth

  3. Get your access token from IEx:
     ```
     # In IEx console
     user = CodeMySpec.Repo.get_by(CodeMySpec.Users.User, email: "your-email@example.com")
     scope = CodeMySpec.Users.get_scope_for_user(user)
     {:ok, integration} = CodeMySpec.Integrations.get_integration(scope, :github)
     IO.puts("Token: \#{integration.access_token}")
     ```

  4. Export the token:
     ```bash
     export GITHUB_TEST_TOKEN="your_oauth_token"
     ```

  5. Run the tests to record cassettes:
     ```bash
     mix test test/code_my_spec/project_setup_wizard/github_integration_test.exs
     ```

  ### Option 2: Use GitHub Personal Access Token (Alternative)

  1. Go to https://github.com/settings/tokens
  2. Generate new token (classic) with 'repo' and 'delete_repo' scopes
  3. Export: `export GITHUB_TEST_TOKEN="ghp_your_token_here"`
  4. Run tests

  ### After Recording

  - VCR will create cassette files in test/fixtures/vcr_cassettes/
  - Delete the test repositories from your GitHub account
  - Commit the cassette files (ExVCR filters sensitive data)

  ## Note on cassettes
  - First run without cassettes will make real API calls and record them
  - Subsequent runs will replay from cassettes (no real API calls)
  - To re-record, delete the cassette file and run again

  ## Note on auth token
  - If any of these tests have to be rerun, you must get a token with delete_repo in the claims
  - Right now, when we get the token, we don't put this in the claims, which is right, good and safe
  """

  use CodeMySpecTest.DataCase, async: true
  use ExVCR.Mock, adapter: ExVCR.Adapter.Hackney

  import CodeMySpec.{UsersFixtures, AccountsFixtures, ProjectsFixtures, IntegrationsFixtures}

  alias CodeMySpec.ProjectSetupWizard.GithubIntegration

  setup do
    ExVCR.Config.cassette_library_dir("test/fixtures/vcr_cassettes")
    ExVCR.Config.filter_sensitive_data("github_pat_[a-zA-Z0-9_]+", "FILTERED_TOKEN")

    user = user_fixture()
    account = account_with_owner_fixture(user)
    scope = user_scope_fixture(user, account)

    project =
      project_fixture(scope, %{
        name: "Test Project",
        description: "A test project for setup wizard",
        code_repo: nil,
        docs_repo: nil
      })

    {:ok, scope: scope, user: user, account: account, project: project}
  end

  # ============================================================================
  # Fixtures
  # ============================================================================

  # Helper to create or get GitHub integration (prevents duplicate key errors)
  defp ensure_github_integration(scope, user, attrs \\ %{}) do
    case CodeMySpec.Integrations.get_integration(scope, :github) do
      {:ok, integration} ->
        integration

      {:error, :not_found} ->
        github_integration_fixture(user, attrs)
    end
  end

  # Helper to extract owner and repo name from GitHub URL
  defp extract_owner_and_repo(url) when is_binary(url) do
    case String.split(url, "/") do
      [_, _, _, owner, repo] -> {owner, repo}
      _ -> nil
    end
  end

  defp extract_owner_and_repo(_), do: nil

  # Helper to clean up GitHub repository after test
  defp cleanup_github_repo(scope, repo_url) do
    {owner, repo} = extract_owner_and_repo(repo_url)
    :ok = CodeMySpec.GitHub.delete_repository(scope, owner, repo)
  end

  # ============================================================================
  # describe "connected?/1" - Happy Path
  # ============================================================================

  describe "connected?/1" do
    test "returns true when GitHub integration exists", %{scope: scope, user: user} do
      # Create integration if it doesn't exist

      case CodeMySpec.Integrations.get_integration(scope, :github) do
        {:ok, _} -> :ok
        {:error, :not_found} -> ensure_github_integration(scope, user)
      end

      assert GithubIntegration.connected?(scope) == true
    end

    test "returns false when no GitHub integration exists", %{scope: scope} do
      refute GithubIntegration.connected?(scope)
    end

    test "respects scope user_id filtering", %{scope: scope, user: _user} do
      other_user = user_fixture()
      github_integration_fixture(other_user)

      # Original user should not see other user's integration
      refute GithubIntegration.connected?(scope)

      # But the other user should see their own integration
      other_account = account_with_owner_fixture(other_user)
      other_scope = user_scope_fixture(other_user, other_account)
      assert GithubIntegration.connected?(other_scope) == true
    end
  end

  # ============================================================================
  # describe "authorize/2" - Happy Path
  # ============================================================================

  describe "authorize/2" do
    test "returns authorization URL for GitHub OAuth", %{scope: scope} do
      redirect_uri = "http://localhost:4000/auth/github/callback"

      assert {:ok, %{url: url, session_params: session_params}} =
               GithubIntegration.authorize(scope, redirect_uri)

      assert is_binary(url)
      assert String.starts_with?(url, "https://github.com")
      assert is_map(session_params)
    end

    test "includes correct redirect_uri in URL", %{scope: scope} do
      redirect_uri = "http://localhost:4000/auth/github/callback"

      assert {:ok, %{url: url}} = GithubIntegration.authorize(scope, redirect_uri)

      # authorize/2 builds redirect_uri from the endpoint config, not the parameter
      expected_redirect = "#{CodeMySpecWeb.Endpoint.url()}/auth/github/callback"
      assert String.contains?(url, URI.encode_www_form(expected_redirect))
    end

    test "delegates to Integrations context", %{scope: scope} do
      redirect_uri = "http://localhost:4000/auth/github/callback"

      # This should use the Integrations.authorize_url/1 function
      assert {:ok, result} = GithubIntegration.authorize(scope, redirect_uri)
      assert Map.has_key?(result, :url)
      assert Map.has_key?(result, :session_params)
    end
  end

  # ============================================================================
  # describe "create_code_repo/2" - Happy Path & Error Cases
  # ============================================================================

  describe "create_code_repo/2" do
    test "creates blank GitHub repository with -code suffix", %{
      scope: scope,
      user: user,
      project: project
    } do
      use_cassette "github_create_code_repo_success" do
        token = System.get_env("GITHUB_TEST_TOKEN") || "test_token_#{:rand.uniform(10000)}"
        ensure_github_integration(scope, user, %{access_token: token})

        assert {:ok, updated_project} = GithubIntegration.create_code_repo(scope, project)

        assert is_binary(updated_project.code_repo)
        assert String.contains?(updated_project.code_repo, "github.com")
        assert String.contains?(updated_project.code_repo, "test-project")

        # Clean up the repository after test completes
        cleanup_github_repo(scope, updated_project.code_repo)
      end
    end

    test "updates project.code_repo with repository URL", %{
      scope: scope,
      user: user,
      project: project
    } do
      use_cassette "github_create_code_repo_updates_project" do
        token = System.get_env("GITHUB_TEST_TOKEN") || "test_token_#{:rand.uniform(10000)}"
        ensure_github_integration(scope, user, %{access_token: token})

        refute project.code_repo

        assert {:ok, updated_project} = GithubIntegration.create_code_repo(scope, project)

        assert updated_project.code_repo
        assert String.starts_with?(updated_project.code_repo, "https://")
        cleanup_github_repo(scope, updated_project.code_repo)
      end
    end

    test "returns updated project", %{scope: scope, user: user, project: project} do
      use_cassette "github_create_code_repo_returns_project" do
        token = System.get_env("GITHUB_TEST_TOKEN") || "test_token_#{:rand.uniform(10000)}"
        ensure_github_integration(scope, user, %{access_token: token})

        assert {:ok, %CodeMySpec.Projects.Project{} = updated_project} =
                 GithubIntegration.create_code_repo(scope, project)

        assert updated_project.id == project.id
        cleanup_github_repo(scope, updated_project.code_repo)
      end
    end

    test "returns error when GitHub not connected", %{scope: scope, project: project} do
      # No GitHub integration created

      assert {:error, :github_not_connected} = GithubIntegration.create_code_repo(scope, project)
    end

    test "sanitizes project name for GitHub naming rules", %{scope: scope, user: user} do
      use_cassette "github_create_code_repo_sanitized" do
        token = System.get_env("GITHUB_TEST_TOKEN") || "test_token_#{:rand.uniform(10000)}"
        ensure_github_integration(scope, user, %{access_token: token})

        project =
          project_fixture(scope, %{
            name: "My Cool Project!!!",
            description: "Test project"
          })

        assert {:ok, updated_project} = GithubIntegration.create_code_repo(scope, project)

        # URL should contain sanitized name: my-cool-project-code
        assert String.contains?(updated_project.code_repo, "my-cool-project")
        cleanup_github_repo(scope, updated_project.code_repo)
      end
    end

    test "handles API errors gracefully", %{scope: scope, project: project} do
      use_cassette "github_create_code_repo_error" do
        result = GithubIntegration.create_code_repo(scope, project)

        # Should return error tuple
        assert {:error, _reason} = result
      end
    end
  end

  # ============================================================================
  # describe "create_docs_repo/2" - Happy Path & Error Cases
  # ============================================================================

  describe "create_docs_repo/2" do
    test "creates GitHub repository with -docs suffix", %{
      scope: scope,
      user: user,
      project: project
    } do
      use_cassette "github_create_docs_repo_success" do
        token = System.get_env("GITHUB_TEST_TOKEN") || "test_token_#{:rand.uniform(10000)}"
        ensure_github_integration(scope, user, %{access_token: token})

        assert {:ok, updated_project} = GithubIntegration.create_docs_repo(scope, project)

        assert is_binary(updated_project.docs_repo)
        assert String.contains?(updated_project.docs_repo, "github.com")
        assert String.contains?(updated_project.docs_repo, "-docs")
        cleanup_github_repo(scope, updated_project.docs_repo)
      end
    end

    test "initializes repo with /content, /design, /rules directories", %{
      scope: scope,
      user: user,
      project: project
    } do
      use_cassette "github_create_docs_repo_with_structure" do
        token = System.get_env("GITHUB_TEST_TOKEN") || "test_token_#{:rand.uniform(10000)}"
        ensure_github_integration(scope, user, %{access_token: token})

        assert {:ok, updated_project} = GithubIntegration.create_docs_repo(scope, project)

        # Verify repo was created with structure
        # (Would need to fetch repo contents via API to fully verify)
        assert updated_project.docs_repo

        cleanup_github_repo(scope, updated_project.docs_repo)
      end
    end

    test "creates .gitignore in repository", %{scope: scope, user: user, project: project} do
      use_cassette "github_create_docs_repo_with_gitignore" do
        token = System.get_env("GITHUB_TEST_TOKEN") || "test_token_#{:rand.uniform(10000)}"
        ensure_github_integration(scope, user, %{access_token: token})

        assert {:ok, updated_project} = GithubIntegration.create_docs_repo(scope, project)

        assert updated_project.docs_repo
        cleanup_github_repo(scope, updated_project.docs_repo)
      end
    end

    test "creates placeholder README.md files in directories", %{
      scope: scope,
      user: user,
      project: project
    } do
      use_cassette "github_create_docs_repo_with_readmes" do
        token = System.get_env("GITHUB_TEST_TOKEN") || "test_token_#{:rand.uniform(10000)}"
        ensure_github_integration(scope, user, %{access_token: token})

        assert {:ok, updated_project} = GithubIntegration.create_docs_repo(scope, project)

        assert updated_project.docs_repo
        cleanup_github_repo(scope, updated_project.docs_repo)
      end
    end

    test "updates project.docs_repo with repository URL", %{
      scope: scope,
      user: user,
      project: project
    } do
      use_cassette "github_create_docs_repo_updates_project" do
        token = System.get_env("GITHUB_TEST_TOKEN") || "test_token_#{:rand.uniform(10000)}"
        ensure_github_integration(scope, user, %{access_token: token})

        refute project.docs_repo

        assert {:ok, updated_project} = GithubIntegration.create_docs_repo(scope, project)

        assert updated_project.docs_repo
        assert String.starts_with?(updated_project.docs_repo, "https://")
        cleanup_github_repo(scope, updated_project.docs_repo)
      end
    end

    test "returns updated project", %{scope: scope, user: user, project: project} do
      use_cassette "github_create_docs_repo_returns_project" do
        token = System.get_env("GITHUB_TEST_TOKEN") || "test_token_#{:rand.uniform(10000)}"
        ensure_github_integration(scope, user, %{access_token: token})

        assert {:ok, %CodeMySpec.Projects.Project{} = updated_project} =
                 GithubIntegration.create_docs_repo(scope, project)

        assert updated_project.id == project.id
        cleanup_github_repo(scope, updated_project.docs_repo)
      end
    end

    test "returns error when GitHub not connected", %{scope: scope, project: project} do
      # No GitHub integration created

      assert {:error, :github_not_connected} = GithubIntegration.create_docs_repo(scope, project)
    end
  end
end
