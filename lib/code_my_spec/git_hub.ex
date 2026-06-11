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

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:github_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_auth(%Scope{} = scope) do
    case Integrations.get_integration(scope, :github) do
      {:ok, integration} -> {:ok, integration.access_token}
      {:error, :not_found} -> {:error, :github_not_connected}
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
