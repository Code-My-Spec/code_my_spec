defmodule CodeMySpecWeb.OAuthControllerTest do
  use CodeMySpecTest.ConnCase, async: true

  import ExUnit.CaptureLog
  import CodeMySpec.UsersFixtures

  describe "GET /oauth/authorize" do
    test "redirects to login when user not authenticated", %{conn: conn} do
      params = %{
        "client_id" => "test-client",
        "redirect_uri" => "https://example.com/callback",
        "response_type" => "code",
        "scope" => "read"
      }

      conn = get(conn, ~p"/oauth/authorize", params)

      assert redirected_to(conn) == ~p"/users/log-in"
      assert get_session(conn, :oauth_params) == params
    end

    test "shows authorization page when user is authenticated", %{conn: conn} do
      user = user_fixture()
      client = oauth_application_fixture()

      conn =
        conn
        |> log_in_user(user)
        |> get(~p"/oauth/authorize", %{
          "client_id" => client.uid,
          "redirect_uri" => client.redirect_uri,
          "response_type" => "code",
          "scope" => "read"
        })

      assert html_response(conn, 200) =~ "Authorize Application"
      assert html_response(conn, 200) =~ client.name
    end

    test "returns error for invalid client", %{conn: conn} do
      user = user_fixture()

      capture_log(fn ->
        conn =
          conn
          |> log_in_user(user)
          |> get(~p"/oauth/authorize", %{
            "client_id" => "invalid-client",
            "redirect_uri" => "https://example.com/callback",
            "response_type" => "code",
            "scope" => "read"
          })

        # Should return an error response instead of redirect for invalid client
        assert conn.status == 422
      end)
    end
  end

  describe "POST /oauth/token" do
    test "grants client credentials token with valid credentials", %{conn: conn} do
      client = oauth_application_fixture()

      conn =
        post(conn, ~p"/oauth/token", %{
          "grant_type" => "client_credentials",
          "client_id" => client.uid,
          "client_secret" => client.secret,
          "scope" => "read"
        })

      assert %{
               "access_token" => access_token,
               "token_type" => "Bearer",
               "expires_in" => 7200,
               "scope" => "read"
             } = json_response(conn, 200)

      assert is_binary(access_token)
      assert String.length(access_token) > 0
    end

    test "returns error with invalid client credentials", %{conn: conn} do
      conn =
        post(conn, ~p"/oauth/token", %{
          "grant_type" => "client_credentials",
          "client_id" => "invalid-client",
          "client_secret" => "invalid-secret",
          "scope" => "read"
        })

      assert %{
               "error" => "invalid_request"
             } = json_response(conn, 422)
    end

    test "returns error with missing parameters", %{conn: conn} do
      conn =
        post(conn, ~p"/oauth/token", %{
          "grant_type" => "client_credentials"
        })

      assert %{
               "error" => "invalid_request"
             } = json_response(conn, 400)
    end
  end

  describe "POST /oauth/revoke" do
    test "revokes valid access token", %{conn: conn} do
      client = oauth_application_fixture()

      # First get a token
      token_conn =
        post(conn, ~p"/oauth/token", %{
          "grant_type" => "client_credentials",
          "client_id" => client.uid,
          "client_secret" => client.secret,
          "scope" => "read"
        })

      %{"access_token" => access_token} = json_response(token_conn, 200)

      # Then revoke it
      revoke_conn =
        post(conn, ~p"/oauth/revoke", %{
          "token" => access_token,
          "client_id" => client.uid,
          "client_secret" => client.secret
        })

      assert json_response(revoke_conn, 200) == %{}
    end

    test "handles invalid token gracefully", %{conn: conn} do
      client = oauth_application_fixture()

      conn =
        post(conn, ~p"/oauth/revoke", %{
          "token" => "invalid-token",
          "client_id" => client.uid,
          "client_secret" => client.secret
        })

      # Revocation should return success even for invalid tokens (per OAuth2 spec)
      assert json_response(conn, 200) == %{}
    end
  end

  describe "GET /.well-known/oauth-protected-resource" do
    test "the bare route names the shared /mcp resource", %{conn: conn} do
      conn = get(conn, "/.well-known/oauth-protected-resource")

      assert %{"resource" => resource} = json_response(conn, 200)
      assert resource == CodeMySpecWeb.Endpoint.url() <> "/mcp"
    end

    test "a path-suffixed request names the exact resource a client is connecting to", %{
      conn: conn
    } do
      # Every mount under /mcp used to get back the same "<base_url>/mcp" no
      # matter which one asked, because the *path wildcard was ignored. A
      # client validating that this value matches the URL it actually
      # connected to (mcp/harness, not mcp) would fail on every request,
      # independent of any token or auth state — this pins that it now
      # reflects the real path.
      conn = get(conn, "/.well-known/oauth-protected-resource/mcp/harness")

      assert %{"resource" => resource} = json_response(conn, 200)
      assert resource == CodeMySpecWeb.Endpoint.url() <> "/mcp/harness"
    end

    test "a different mount's path is named just as precisely", %{conn: conn} do
      conn = get(conn, "/.well-known/oauth-protected-resource/mcp/stories")

      assert %{"resource" => resource} = json_response(conn, 200)
      assert resource == CodeMySpecWeb.Endpoint.url() <> "/mcp/stories"
    end
  end

  describe "the 401 an unauthenticated MCP request gets back" do
    test "realm names the exact resource requested, not the shared /mcp parent", %{conn: conn} do
      conn = get(conn, "/mcp/harness")

      assert conn.status == 401
      [challenge] = get_resp_header(conn, "www-authenticate")
      assert challenge =~ ~s(realm="#{CodeMySpecWeb.Endpoint.url()}/mcp/harness")
      refute challenge =~ ~s(realm="#{CodeMySpecWeb.Endpoint.url()}/mcp"\")
    end

    test "resource_metadata points a client at that resource's own discovery doc", %{
      conn: conn
    } do
      # RFC 9728 §5.1 — without this a client has to guess the discovery
      # URL rather than being told it.
      conn = get(conn, "/mcp/harness")

      [challenge] = get_resp_header(conn, "www-authenticate")

      assert challenge =~
               ~s(resource_metadata="#{CodeMySpecWeb.Endpoint.url()}/.well-known/oauth-protected-resource/mcp/harness")
    end
  end

  # Helper function to create OAuth application fixture
  defp oauth_application_fixture(attrs \\ %{}) do
    attrs =
      attrs
      |> Enum.into(%{
        name: "Test Application",
        uid: "test-client-#{System.unique_integer([:positive])}",
        secret: "test-secret-#{:crypto.strong_rand_bytes(32) |> Base.encode64()}",
        redirect_uri: "https://example.com/callback",
        scopes: "read write"
      })

    # Insert directly without changeset since the OAuth schema doesn't expose it
    {1, [app]} =
      CodeMySpec.Repo.insert_all(
        "oauth_applications",
        [
          Map.merge(attrs, %{
            inserted_at: DateTime.utc_now(),
            updated_at: DateTime.utc_now()
          })
        ],
        returning: [:id, :name, :uid, :secret, :redirect_uri, :scopes]
      )

    struct(CodeMySpec.Oauth.Application, app)
  end
end
