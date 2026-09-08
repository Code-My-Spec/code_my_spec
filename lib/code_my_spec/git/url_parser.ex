defmodule CodeMySpec.Git.URLParser do
  @moduledoc """
  Parses HTTPS git repository URLs to extract provider information and construct
  authenticated URLs with injected access tokens.
  """

  @type provider :: :github | :gitlab
  @type url_error :: :invalid_url | :unsupported_provider

  @doc """
  Extracts the git provider from an HTTPS repository URL.

  ## Examples

      iex> provider("https://github.com/owner/repo.git")
      {:ok, :github}

      iex> provider("https://gitlab.com/owner/repo.git")
      {:ok, :gitlab}

      iex> provider("git@github.com:owner/repo.git")
      {:error, :invalid_url}

      iex> provider("https://bitbucket.org/owner/repo.git")
      {:error, :unsupported_provider}
  """
  @spec provider(url :: String.t() | nil) :: {:ok, provider()} | {:error, url_error()}
  def provider(nil), do: {:error, :invalid_url}
  def provider(""), do: {:error, :invalid_url}

  def provider(url) when is_binary(url) do
    with {:ok, uri} <- parse_https_url(url),
         {:ok, host} <- extract_host(uri) do
      map_host_to_provider(host)
    end
  end

  @doc """
  Injects an access token into an HTTPS repository URL for authentication.

  ## Examples

      iex> inject_token("https://github.com/owner/repo.git", "ghp_token123")
      {:ok, "https://ghp_token123@github.com/owner/repo.git"}

      iex> inject_token("git@github.com:owner/repo.git", "token")
      {:error, :invalid_url}
  """
  @spec inject_token(url :: String.t() | nil, token :: String.t() | nil) ::
          {:ok, String.t()} | {:error, :invalid_url}
  def inject_token(nil, _token), do: {:error, :invalid_url}
  def inject_token("", _token), do: {:error, :invalid_url}

  def inject_token(url, token) when is_binary(url) do
    with {:ok, uri} <- parse_https_url(url) do
      build_authenticated_url(uri, token)
    end
  end

  # Private Functions

  defp parse_https_url(url) do
    uri = URI.parse(url)

    case uri do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
        {:ok, uri}

      _ ->
        {:error, :invalid_url}
    end
  end

  defp extract_host(%URI{host: host}) when is_binary(host) do
    normalized_host = String.downcase(host)
    {:ok, normalized_host}
  end

  defp map_host_to_provider("github.com"), do: {:ok, :github}
  defp map_host_to_provider("gitlab.com"), do: {:ok, :gitlab}
  defp map_host_to_provider(_), do: {:error, :unsupported_provider}

  defp build_authenticated_url(%URI{} = uri, token) do
    authenticated_uri = %URI{uri | userinfo: token_to_userinfo(token)}
    {:ok, URI.to_string(authenticated_uri)}
  end

  defp token_to_userinfo(nil), do: nil
  defp token_to_userinfo(token) when is_binary(token), do: token
end
