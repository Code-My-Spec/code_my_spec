defmodule CodeMySpec.GitHubTest do
  @moduledoc """
  Cassette-backed test for the hand-written Req GitHub client.

  The cassette replays a canned `POST /user/repos` 201 response so the test
  exercises the full token → Req → response-shape path without ever hitting
  GitHub. Re-record by deleting the cassette, switching `cassette_opts/0` to
  `mode: :record`, and running with a real GitHub token in scope — but prefer
  the committed replay cassette to avoid creating throwaway repos.
  """

  use CodeMySpecTest.DataCase, async: false

  import ReqCassette
  import CodeMySpec.UsersFixtures
  import CodeMySpec.IntegrationsFixtures

  alias CodeMySpec.GitHub
  alias CodeMySpec.Users.Scope

  @cassette_dir "test/cassettes/github"

  setup do
    on_exit(fn -> Application.put_env(:code_my_spec, GitHub, plug: nil) end)
    :ok
  end

  describe "create_repository/2" do
    test "creates a repo and returns the decoded body" do
      user = user_fixture()
      github_integration_fixture(user)
      scope = %Scope{user: user}

      with_cassette "create_repo_success", cassette_opts(), fn plug ->
        with_plug(plug, fn ->
          attrs = %{name: "req-client-test", description: "A test project", private: true}

          assert {:ok, %{"html_url" => url}} = GitHub.create_repository(scope, attrs)
          assert url == "https://github.com/testuser/req-client-test"
        end)
      end
    end

    test "returns :github_not_connected when no GitHub integration exists" do
      user = user_fixture()
      scope = %Scope{user: user}

      assert {:error, :github_not_connected} =
               GitHub.create_repository(scope, %{name: "nope"})
    end
  end

  defp with_plug(plug, fun) do
    # The `setup` block resets the plug via on_exit after every test, so
    # this only needs to install it for the duration of the test body.
    Application.put_env(:code_my_spec, GitHub, plug: plug)
    fun.()
  end

  defp cassette_opts do
    [
      cassette_dir: @cassette_dir,
      mode: :replay,
      match_requests_on: [:method, :uri],
      filter_request_headers: ["authorization"]
    ]
  end
end
