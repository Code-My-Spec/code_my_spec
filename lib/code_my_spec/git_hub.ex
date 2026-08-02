defmodule CodeMySpec.GitHub do
  @moduledoc """
  GitHub API operations using provided access tokens.

  This context is a thin authentication wrapper around the GitHub REST API. It
  retrieves a GitHub access token from the Integrations context and uses it to
  make authenticated requests via `Req`. Only the operations CodeMySpec actually
  uses live here.

  It does not manage authentication or persist repository state — it simply
  bridges user scope to authenticated API calls.

  ## Supported Operations

  - Create a repository for the authenticated user
  """

  alias CodeMySpec.Integrations
  alias CodeMySpec.Users.Scope

  @api_base "https://api.github.com"

  @doc """
  Creates a new repository for the authenticated user.

  ## Parameters
  - `scope` - User scope for multi-tenant isolation
  - `attrs` - Repository attributes (name, description, private, etc.)

  ## Examples

      iex> create_repository(scope, %{name: "my-repo", private: true})
      {:ok, %{"html_url" => "https://github.com/octocat/my-repo"}}

      iex> create_repository(scope, %{name: "my-repo"})
      {:error, :github_not_connected}
  """
  @spec create_repository(Scope.t(), map()) ::
          {:ok, map()}
          | {:error, :github_not_connected}
          | {:error, {:github_error, integer(), term()}}
          | {:error, term()}
  def create_repository(%Scope{} = scope, attrs) do
    with {:ok, token} <- get_auth(scope) do
      request(:post, "/user/repos", token, json: attrs)
    end
  end

  @doc """
  Fetch a repository by owner and name.

  Returns `{:error, :not_found}` for a 404 rather than a generic error, because
  "this name is free" and "GitHub is unhappy" are different answers and callers
  branch on them.
  """
  @spec get_repository(Scope.t(), String.t(), String.t()) ::
          {:ok, map()}
          | {:error, :not_found}
          | {:error, :github_not_connected}
          | {:error, {:github_error, integer(), term()}}
          | {:error, term()}
  def get_repository(%Scope{} = scope, owner, name)
      when is_binary(owner) and is_binary(name) do
    with {:ok, token} <- get_auth(scope) do
      case request(:get, "/repos/#{owner}/#{name}", token, []) do
        {:ok, repo} -> {:ok, repo}
        {:error, {:github_error, 404, _}} -> {:error, :not_found}
        other -> other
      end
    end
  end

  @doc """
  The login the grant belongs to.

  Needed because "adopt an existing repository rather than create a second
  one" cannot be checked without knowing whose account to look in. Guessing
  from the project would check the wrong account and report a name free that
  is not — so ask GitHub who the token is.
  """
  @spec authenticated_login(Scope.t()) ::
          {:ok, String.t()} | {:error, :github_not_connected} | {:error, term()}
  def authenticated_login(%Scope{} = scope) do
    with {:ok, token} <- get_auth(scope),
         {:ok, %{"login" => login}} <- request(:get, "/user", token, []) do
      {:ok, login}
    else
      {:ok, _body} -> {:error, :no_login}
      other -> other
    end
  end

  @doc """
  Repositories the grant can see, most recently pushed first.

  Needed because this is an OAuth App: there is no installation screen where
  the user picks repositories, so choosing one is our job. `affiliation`
  defaults to `owner` — repositories Sam owns are the ones he can make a
  project's remote.
  """
  @spec list_repositories(Scope.t(), keyword()) ::
          {:ok, [map()]} | {:error, :github_not_connected} | {:error, term()}
  def list_repositories(%Scope{} = scope, opts \\ []) do
    affiliation = Keyword.get(opts, :affiliation, "owner")
    per_page = Keyword.get(opts, :per_page, 100)

    with {:ok, token} <- get_auth(scope),
         {:ok, repos} when is_list(repos) <-
           request(
             :get,
             "/user/repos?affiliation=#{affiliation}&sort=pushed&per_page=#{per_page}",
             token,
             []
           ) do
      {:ok, repos}
    else
      {:ok, _not_a_list} -> {:ok, []}
      {:error, _} = error -> error
    end
  end

  @doc """
  Create a repository inside an organisation.

  A different endpoint from `create_repository/2`, not a parameter on it —
  GitHub treats org repositories as a separate resource with its own
  permission.
  """
  @spec create_org_repository(Scope.t(), String.t(), map()) ::
          {:ok, map()} | {:error, :github_not_connected} | {:error, term()}
  def create_org_repository(%Scope{} = scope, org, attrs) when is_binary(org) do
    with {:ok, token} <- get_auth(scope) do
      request(:post, "/orgs/#{org}/repos", token, json: attrs)
    end
  end

  # Private Helpers

  defp request(method, path, token, opts) do
    req_opts =
      [
        method: method,
        url: @api_base <> path,
        headers: [
          {"authorization", "Bearer #{token}"},
          {"accept", "application/vnd.github+json"},
          {"x-github-api-version", "2022-11-28"},
          {"user-agent", "CodeMySpec"}
        ]
      ]
      |> Keyword.merge(opts)
      |> Keyword.merge(plug_opt())

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      # A 401 is a revoked or expired authorization, not a request problem —
      # the token GitHub was handed is no longer good. Surfacing it as
      # `:github_not_connected` is what lets the caller say "reconnect GitHub"
      # rather than "could not create the repository", which points Sam at the
      # wrong thing (criterion 8181).
      {:ok, %Req.Response{status: 401, body: _body}} ->
        {:error, :github_not_connected}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:github_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_auth(%Scope{} = scope) do
    case Integrations.fetch_access_token(scope, :github) do
      {:ok, token} -> {:ok, token}
      {:error, :not_found} -> {:error, :github_not_connected}
      {:error, :reauthorize_required} -> {:error, :github_not_connected}
      {:error, _reason} -> {:error, :github_not_connected}
    end
  end

  # Tests inject a ReqCassette plug via Application.put_env so HTTP can be
  # recorded/replayed against a cassette without hitting GitHub.
  defp plug_opt do
    case Application.get_env(:code_my_spec, __MODULE__, []) |> Keyword.get(:plug) do
      nil -> []
      plug -> [plug: plug]
    end
  end
end
