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

  # Any credential but a revoked one.
  #
  # 8181's premise is a connection Sam has revoked, and `break_provider_credential/2`
  # states it by storing this exact token — so that is what the account
  # refuses, and everything else it accepts.
  #
  # The first version pinned one valid token instead. That reads as more
  # faithful and models a relationship the suite does not have: credentials
  # arrive from `fake_providers/1`, from a paste into the credentials form,
  # and from fixtures, and none of them agree on a value. Every paste 401'd,
  # the page's credential proof retried, and 966/8003 spent its whole
  # three-minute timeout inside `render_submit`.
  @revoked "spex-deliberately-invalid-token"

  @doc """
  Put a repository in the account without creating it.

  A premise, for the criteria that start from one already being there —
  adoption (8179) and the colliding name (8185). Under recordings that was true
  because an earlier run had left one, so those criteria passed on a dirty
  account and failed on a clean one.
  """
  def add_repository(agent, owner, name) do
    Agent.update(agent, fn state ->
      {_status, %{repos: repos, next_id: next_id}} = create(%{"name" => name}, owner, state)
      %{state | repos: repos, next_id: next_id}
    end)
  end

  def call(conn, agent) do
    conn = Conn.fetch_query_params(conn)

    case authorized?(conn) do
      true -> dispatch(conn, agent)
      false -> unauthorized(conn)
    end
  end

  # A revoked token is a 401, which is what GitHub answers and what
  # `GitHub.request/4` translates into `:github_not_connected` — "reconnect
  # GitHub" rather than "could not create the repository". Criterion 8181's
  # whole premise is a connection that no longer works, and a fake that
  # ignored the credential would let the step sail through the revocation and
  # complete.
  defp authorized?(conn) do
    Conn.get_req_header(conn, "authorization") != ["Bearer #{@revoked}"]
  end

  defp unauthorized(conn) do
    conn
    |> Conn.put_resp_content_type("application/json")
    |> Conn.send_resp(401, Jason.encode!(%{"message" => "Bad credentials"}))
  end

  defp dispatch(conn, agent) do
    {status, body} =
      Agent.get_and_update(agent, &route(conn.method, conn.request_path, body_of(conn), &1))

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
