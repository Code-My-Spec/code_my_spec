defmodule CodeMySpec.Git do
  @moduledoc """
  Context module for Git operations using authenticated credentials.

  Provides a thin wrapper around Git CLI operations for cloning and pulling
  repositories using OAuth tokens from the Integrations context.

  ## Responsibilities
  - Delegates git operations to Git.CLI component
  - Public API surface for Git functionality
  - No state management (stateless operations)

  ## Authentication Flow
  All operations require a `Scope.t()` to retrieve integration credentials:
  1. Parse repository URL to determine provider (GitHub, GitLab, etc.)
  2. Retrieve integration credentials for that provider
  3. Inject credentials into repository URL
  4. Execute git operation
  5. Clean up credentials from git configuration
  """

  use Boundary,
    top_level?: true,
    deps: [CodeMySpec.Environments, CodeMySpec.Integrations, CodeMySpec.Users],
    exports: :all

  @behaviour CodeMySpec.Git.Behaviour

  alias CodeMySpec.Git.CLI
  alias CodeMySpec.Users.Scope

  @type repo_url :: String.t()
  @type path :: String.t()
  @type error_reason :: :not_connected | :unsupported_provider | :invalid_url | term()

  defp impl do
    Application.get_env(:code_my_spec, :git_impl_module, CLI)
  end

  @doc """
  Clones a git repository using authenticated credentials from the user's integrations.

  ## Parameters
  - `scope` - User scope for retrieving integration credentials
  - `repo_url` - HTTPS repository URL to clone from
  - `path` - Local filesystem path where repository should be cloned

  ## Returns
  - `{:ok, path}` - Successfully cloned repository
  - `{:error, :not_connected}` - No integration found for provider
  - `{:error, :unsupported_provider}` - Provider not supported
  - `{:error, :invalid_url}` - Invalid repository URL format
  - `{:error, reason}` - Git operation failed

  ## Examples

      iex> clone(scope, "https://github.com/owner/repo.git", "/tmp/repo")
      {:ok, "/tmp/repo"}

      iex> clone(scope, "invalid-url", "/tmp/repo")
      {:error, :invalid_url}

      iex> clone(scope, "https://github.com/owner/repo.git", "/tmp/repo")
      {:error, :not_connected}
  """
  @spec clone(Scope.t(), repo_url(), path()) :: {:ok, path()} | {:error, error_reason()}
  def clone(scope, repo_url, path), do: impl().clone(scope, repo_url, path)

  @doc """
  Pulls changes from the remote repository using authenticated credentials.

  Temporarily injects credentials into the remote URL, performs the pull,
  then restores the original URL without credentials.

  ## Parameters
  - `scope` - User scope for retrieving integration credentials
  - `path` - Local filesystem path to the git repository

  ## Returns
  - `:ok` - Successfully pulled changes
  - `{:error, :not_connected}` - No integration found for provider
  - `{:error, :unsupported_provider}` - Provider not supported
  - `{:error, reason}` - Git operation failed

  ## Examples

      iex> pull(scope, "/tmp/repo")
      :ok

      iex> pull(scope, "/nonexistent/path")
      {:error, _reason}
  """
  @spec pull(Scope.t(), path()) :: :ok | {:error, error_reason()}
  def pull(scope, path), do: impl().pull(scope, path)
end
