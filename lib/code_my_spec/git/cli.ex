defmodule CodeMySpec.Git.CLI do
  @moduledoc """
  Wraps git operations for cloning and pulling repositories with authenticated URLs.

  Retrieves OAuth access tokens from the Integrations context, injects them into
  repository URLs, and delegates git operations to the git_cli library.
  """

  alias CodeMySpec.Git.URLParser
  alias CodeMySpec.Integrations
  alias CodeMySpec.Users.Scope

  @type repo_url :: String.t()
  @type path :: String.t()
  @type error_reason :: :not_connected | :unsupported_provider | :invalid_url | term()

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
  """
  @spec clone(Scope.t(), repo_url(), path()) :: {:ok, path()} | {:error, error_reason()}
  def clone(%Scope{} = scope, repo_url, path) do
    with {:ok, provider} <- URLParser.provider(repo_url),
         {:ok, integration} <- get_integration(scope, provider),
         {:ok, authenticated_url} <- URLParser.inject_token(repo_url, integration.access_token),
         {:ok, _repository} <- Git.clone([authenticated_url, path]),
         :ok <- set_remote_url(path, repo_url) do
      {:ok, path}
    end
  end

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
  def pull(%Scope{}, nil), do: {:error, :invalid_path}
  def pull(%Scope{}, ""), do: {:error, :invalid_path}

  def pull(%Scope{} = scope, path) when is_binary(path) do
    with {:ok, original_url} <- get_remote_url(path),
         {:ok, provider} <- URLParser.provider(original_url),
         {:ok, integration} <- get_integration(scope, provider),
         {:ok, authenticated_url} <-
           URLParser.inject_token(original_url, integration.access_token) do
      # Inject credentials, pull, then restore - always restore URL
      case set_remote_url(path, authenticated_url) do
        :ok ->
          result = execute_pull(path)
          # Always restore original URL, regardless of pull result
          set_remote_url(path, original_url)
          result

        {:error, _reason} = error ->
          error
      end
    else
      {:error, _reason} = error ->
        # Attempt to restore original URL even on error
        restore_remote_url(path)
        error
    end
  end

  # Private Functions

  defp get_integration(scope, provider) do
    case Integrations.get_integration(scope, provider) do
      {:ok, integration} -> {:ok, integration}
      {:error, :not_found} -> {:error, :not_connected}
    end
  end

  defp get_remote_url(path) do
    case System.cmd("git", ["-C", path, "config", "--get", "remote.origin.url"],
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, String.trim(output)}
      {_output, _exit_code} -> {:error, :no_remote}
    end
  end

  defp set_remote_url(path, url) do
    case System.cmd("git", ["remote", "set-url", "origin", url], stderr_to_stdout: true, cd: path) do
      {_output, 0} -> :ok
      {_output, _exit_code} -> {:error, :failed_to_update_remote}
    end
  end

  defp execute_pull(path) do
    case Git.pull(%Git.Repository{path: path}) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp restore_remote_url(path) do
    # Attempt to get current URL and strip credentials
    case get_remote_url(path) do
      {:ok, current_url} -> maybe_strip_remote_credentials(path, current_url)
      _ -> :ok
    end
  end

  # Only restore if URL contains credentials (has @ sign before host).
  defp maybe_strip_remote_credentials(path, current_url) do
    if String.contains?(current_url, "@") do
      case strip_credentials(current_url) do
        {:ok, clean_url} -> set_remote_url(path, clean_url)
        _ -> :ok
      end
    else
      :ok
    end
  end

  defp strip_credentials(url) do
    # Remove credentials from URL
    # e.g., "https://token@github.com/owner/repo.git" -> "https://github.com/owner/repo.git"
    case URI.parse(url) do
      %URI{host: host} = uri when is_binary(host) ->
        # Remove userinfo (credentials) by setting it to nil
        clean_uri = %{uri | userinfo: nil}
        {:ok, URI.to_string(clean_uri)}

      _ ->
        {:error, :invalid_url}
    end
  end
end
