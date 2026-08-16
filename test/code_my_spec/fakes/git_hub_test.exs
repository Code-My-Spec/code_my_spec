defmodule CodeMySpecSpex.Fakes.GitHubTest do
  @moduledoc """
  The GitHub fake's semantics, checked directly.

  Small, because the repository step does little: create, read back, push. The
  behaviours worth pinning are the two that decide whether a *second* run
  works — a repo that is still there, and a duplicate name that is refused
  rather than quietly handed back.
  """
  use ExUnit.Case, async: true

  alias CodeMySpecSpex.Fakes.GitHub

  setup do
    {:ok, agent} = Agent.start_link(&GitHub.new/0)
    %{agent: agent}
  end

  defp request(agent, method, path, body \\ nil) do
    Req.new(
      method: method,
      url: "https://api.github.com" <> path,
      # A credential, because the account checks for the revoked one.
      headers: [{"authorization", "Bearer fake-github-token"}],
      plug: &GitHub.call(&1, agent)
    )
    |> with_body(body)
    |> Req.request!()
  end

  defp with_body(req, nil), do: req
  defp with_body(req, body), do: Req.merge(req, json: body)

  # 8181's premise: Sam revoked the installation. `GitHub.request/4` turns this
  # into `:github_not_connected`, which is what makes the step say "reconnect
  # GitHub" rather than "could not create the repository".
  test "a token the account never issued is refused", %{agent: agent} do
    response =
      Req.request!(
        Req.new(
          method: :get,
          url: "https://api.github.com/user",
          headers: [{"authorization", "Bearer spex-deliberately-invalid-token"}],
          plug: &GitHub.call(&1, agent)
        )
      )

    assert response.status == 401
  end

  test "a created repository is readable back", %{agent: agent} do
    assert %{status: 201, body: repo} = request(agent, :post, "/user/repos", %{"name" => "app"})
    assert repo["full_name"] == "sam/app"

    assert %{status: 200, body: found} = request(agent, :get, "/repos/sam/app")
    assert found["clone_url"] =~ "sam/app"
  end

  # GitHub refuses rather than returning the existing one, which is what makes
  # adoption a code path `ensure_repository/3` has to have. A drill paused on
  # exactly this message.
  test "creating a name that exists is refused", %{agent: agent} do
    %{status: 201} = request(agent, :post, "/user/repos", %{"name" => "app"})

    assert %{status: 422, body: body} = request(agent, :post, "/user/repos", %{"name" => "app"})
    assert to_string(inspect(body)) =~ "already exists"
  end

  test "a repository nobody made is a 404", %{agent: agent} do
    assert %{status: 404} = request(agent, :get, "/repos/sam/nothing")
  end

  test "an unmodelled route says so rather than passing", %{agent: agent} do
    assert %{status: 501, body: body} = request(agent, :get, "/gists")
    assert body["message"] =~ "not modelled"
  end
end
