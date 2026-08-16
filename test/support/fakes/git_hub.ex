defmodule CodeMySpecSpex.Fakes.GitHub do
  @moduledoc """
  A GitHub account that remembers the repositories made in it.

  The last of the provider fakes, and the smallest — the repository step
  creates a repo, reads it back, and pushes to it. What matters is the same
  thing that matters everywhere else here: a repository that exists after it is
  created, so a re-run adopts rather than failing, and a criterion asking "did
  setup make one" gets an answer about this run.

  Modelled where the semantics bite:

    * **Creating a name that exists is a 422**, which is what GitHub answers
      and the case `ensure_repository/3` exists to handle. A drill paused on
      exactly this — "A repository named spex-drill already exists on this
      account" — so it is a real path rather than a hypothetical.

    * **A repository is readable back by owner and name**, which is how the
      step adopts one it did not make.

  The push itself is a `git` subprocess, not an API call, and belongs to the
  shell fake.
  """

  alias Plug.Conn

  @doc "Fresh account state. One per test."
  def new(login \\ "sam"), do: %{login: login, repos: [], next_id: 1}

  def call(conn, agent) do
    conn = Conn.fetch_query_params(conn)
    {status, body} = Agent.get_and_update(agent, &route(conn.method, conn.request_path, body_of(conn), &1))

    conn
    |> Conn.put_resp_content_type("application/json")
    |> Conn.send_resp(status, Jason.encode!(body))
  end

  defp body_of(%{body_params: %Plug.Conn.Unfetched{}}), do: %{}
  defp body_of(%{body_params: params}) when is_map(params), do: params
  defp body_of(_), do: %{}

  defp route("GET", "/user", _body, state) do
    {{200, %{"login" => state.login, "id" => 1}}, state}
  end

  defp route("GET", "/user/repos", _body, state) do
    {{200, state.repos}, state}
  end

  defp route("POST", "/user/repos", body, state), do: create(body, state.login, state)

  defp route("POST", "/orgs/" <> org, body, state) do
    create(body, String.replace_suffix(org, "/repos", ""), state)
  end

  defp route("GET", "/repos/" <> path, _body, state) do
    case Enum.find(state.repos, &(&1["full_name"] == path)) do
      nil -> {{404, %{"message" => "Not Found"}}, state}
      repo -> {{200, repo}, state}
    end
  end

  defp route(method, path, _body, state) do
    {{501, %{"message" => "#{method} #{path} is not modelled by the GitHub fake"}}, state}
  end

  # GitHub refuses a duplicate name rather than handing back the existing one,
  # which is what makes adoption a real code path rather than an accident.
  defp create(body, owner, state) do
    name = body["name"]
    full = "#{owner}/#{name}"

    case Enum.find(state.repos, &(&1["full_name"] == full)) do
      nil ->
        repo = %{
          "id" => state.next_id,
          "name" => name,
          "full_name" => full,
          "private" => body["private"] || false,
          "owner" => %{"login" => owner},
          "clone_url" => "https://github.com/#{full}.git",
          "ssh_url" => "git@github.com:#{full}.git",
          "default_branch" => "main"
        }

        {{201, repo}, %{state | repos: state.repos ++ [repo], next_id: state.next_id + 1}}

      _existing ->
        {{422,
          %{
            "message" => "Repository creation failed.",
            "errors" => [%{"message" => "name already exists on this account"}]
          }}, state}
    end
  end
end
