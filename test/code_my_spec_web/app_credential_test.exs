defmodule CodeMySpecWeb.AppCredentialTest do
  @moduledoc """
  Story 971's central property, at the four surfaces that carry it.

  Every test here asks one of two questions: does an exchanged token open this
  surface, and does the durable key still open it. Both have to be yes at the
  same time — a token path that broke the key would take four live endpoints
  with deployed callers down with it, and a key path that never gained the
  token would leave 8045 and 8046 unmet with the exchange sitting unused.
  """

  # Not async: the configured-key surfaces read `:code_my_spec, :deploy_key`
  # from application env, and setting it is global.
  use CodeMySpecTest.ConnCase, async: false

  import CodeMySpec.ProjectsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AppTokens

  @configured_key "app_credential_test_configured_key"

  setup do
    original = Application.get_env(:code_my_spec, :deploy_key)
    Application.put_env(:code_my_spec, :deploy_key, @configured_key)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:code_my_spec, :deploy_key)
        key -> Application.put_env(:code_my_spec, :deploy_key, key)
      end
    end)

    scope = full_scope_fixture()

    deploy_key = :crypto.strong_rand_bytes(64) |> Base.encode16(case: :lower)
    project = project_fixture(scope, %{deploy_key: deploy_key})

    secret = "refresh-" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    {:ok, project} = AppTokens.put_refresh_secret(project, secret)
    {:ok, token, _} = AppTokens.exchange(secret)

    %{project: project, secret: secret, token: token, deploy_key: deploy_key}
  end

  defp bearer(conn, credential), do: put_req_header(conn, "authorization", "Bearer #{credential}")

  describe "criterion 8021 — one credential covers issues, users, content and the widget" do
    test "the same token opens the project-resolving surfaces", %{conn: conn, token: token} do
      issues =
        conn
        |> bearer(token)
        |> post(~p"/api/framework/issues", %{
          "issue" => %{"title" => "from a token", "description" => "d", "severity" => "low"}
        })

      assert issues.status in [200, 201], "framework/issues refused a valid access token"

      users =
        build_conn()
        |> bearer(token)
        |> post(~p"/api/widget/users", %{
          "user" => %{"email" => "visitor@example.com", "external_id" => "v1"}
        })

      assert users.status in [200, 201], "widget/users refused a valid access token"
    end

    test "the same token opens the configured-key surfaces", %{conn: conn, token: token} do
      cms_users = conn |> bearer(token) |> get(~p"/api/cms/users")
      assert cms_users.status == 200, "cms/users refused a valid access token"

      sync =
        build_conn()
        |> bearer(token)
        |> post(~p"/api/content/sync", %{"content" => [], "synced_at" => "2026-08-01T00:00:00Z"})

      assert sync.status == 200, "content/sync refused a valid access token"
    end
  end

  describe "the durable key keeps working" do
    # These are live endpoints with deployed callers. Adding the token path is
    # only safe because it is additive; this is the test that says so.
    test "a project's deploy key still opens the surfaces that resolve a project", %{
      conn: conn,
      deploy_key: deploy_key
    } do
      response =
        conn
        |> bearer(deploy_key)
        |> post(~p"/api/framework/issues", %{
          "issue" => %{"title" => "from the key", "description" => "d", "severity" => "low"}
        })

      assert response.status in [200, 201]
    end

    test "the configured key still opens the surfaces that compare one", %{conn: conn} do
      assert conn |> bearer(@configured_key) |> get(~p"/api/cms/users") |> Map.fetch!(:status) ==
               200
    end
  end

  describe "criteria 8045 and 8046 — the refresh secret buys a token and nothing else" do
    test "the refresh secret is refused as a bearer credential everywhere", %{
      conn: conn,
      secret: secret
    } do
      assert conn |> bearer(secret) |> get(~p"/api/cms/users") |> Map.fetch!(:status) == 401

      assert build_conn()
             |> bearer(secret)
             |> post(~p"/api/framework/issues", %{
               "issue" => %{"title" => "t", "description" => "d", "severity" => "low"}
             })
             |> Map.fetch!(:status) == 401

      assert build_conn()
             |> bearer(secret)
             |> post(~p"/api/widget/users", %{"user" => %{"email" => "a@b.c"}})
             |> Map.fetch!(:status) == 401

      assert build_conn()
             |> bearer(secret)
             |> post(~p"/api/content/sync", %{"content" => [], "synced_at" => "2026-08-01T00:00:00Z"})
             |> Map.fetch!(:status) == 401
    end

    test "but it does buy a token", %{conn: conn, secret: secret} do
      response = post(conn, ~p"/api/token", %{"refresh_secret" => secret})
      assert %{"access_token" => token} = json_response(response, 200)
      assert {:ok, _project} = AppTokens.verify(token)
    end
  end

  describe "criterion 8023 — a refusal says why, so the app knows to renew" do
    setup %{project: project} do
      # Signed in the past rather than waited for: a fifteen-minute window is
      # not something a test can sit through, and the distinction under test is
      # in the verification, not in the clock.
      expired =
        Phoenix.Token.sign(
          Application.get_env(:code_my_spec, CodeMySpecWeb.Endpoint)[:secret_key_base],
          "app access token",
          {project.id, "nonce"},
          signed_at: System.system_time(:second) - AppTokens.max_age() - 60
        )

      %{expired: expired}
    end

    test "an aged-out token is distinguishable from a wrong one", %{conn: conn, expired: expired} do
      aged = conn |> bearer(expired) |> get(~p"/api/cms/users")
      assert aged.status == 401
      assert json_response(aged, 401)["reason"] == "expired"

      wrong = build_conn() |> bearer("not-a-credential") |> get(~p"/api/cms/users")
      assert wrong.status == 401

      refute json_response(wrong, 401)["reason"] == "expired",
             "a wrong credential reported as expired — the app would renew forever"
    end

    test "the exchange itself does not explain why a secret failed", %{conn: conn} do
      # Deliberately one answer: telling an unauthenticated caller why their
      # secret failed tells an attacker the same thing.
      response = post(conn, ~p"/api/token", %{"refresh_secret" => "wrong"})
      assert response.status == 401
      refute json_response(response, 401)["reason"] == "expired"
    end
  end
end
