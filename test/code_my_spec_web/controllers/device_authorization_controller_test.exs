defmodule CodeMySpecWeb.DeviceAuthorizationControllerTest do
  @moduledoc """
  Issue 94cb8e04 -- the device authorization grant's HTTP surface, end to
  end: a harness requests a code, a person decides it on the page RFC 8628
  describes, and the harness polls `/oauth/token` for the result.
  """

  use CodeMySpecTest.ConnCase, async: true

  import CodeMySpec.OauthFixtures
  import CodeMySpec.AccountsFixtures
  import CodeMySpec.ProjectsFixtures
  import CodeMySpec.UsersFixtures

  describe "POST /oauth/device/code" do
    test "issues a device code for a registered client", %{conn: conn} do
      client = oauth_application_fixture()

      conn =
        post(conn, ~p"/oauth/device/code", %{
          "client_id" => client.uid,
          "device_id" => Ecto.UUID.generate()
        })

      assert %{
               "device_code" => device_code,
               "user_code" => user_code,
               "verification_uri" => verification_uri,
               "verification_uri_complete" => verification_uri_complete,
               "expires_in" => expires_in,
               "interval" => 5
             } = json_response(conn, 200)

      assert is_binary(device_code)
      assert user_code =~ ~r/^[A-Z2-9]{4}-[A-Z2-9]{4}$/
      assert verification_uri == "http://www.example.com/oauth/device"

      assert verification_uri_complete ==
               verification_uri <> "?user_code=" <> URI.encode(user_code)

      assert expires_in > 0
    end

    test "uses the server that received the request for verification", %{conn: conn} do
      client = oauth_application_fixture()
      conn = %{conn | host: "localhost", port: 4000, scheme: :http}

      response =
        post(conn, ~p"/oauth/device/code", %{
          "client_id" => client.uid,
          "device_id" => Ecto.UUID.generate()
        })

      assert %{
               "verification_uri" => "http://localhost:4000/oauth/device",
               "verification_uri_complete" => complete
             } = json_response(response, 200)

      assert String.starts_with?(complete, "http://localhost:4000/oauth/device?user_code=")
    end

    test "refuses an unregistered client", %{conn: conn} do
      conn =
        post(conn, ~p"/oauth/device/code", %{
          "client_id" => "no-such-client",
          "device_id" => Ecto.UUID.generate()
        })

      assert %{"error" => "invalid_client"} = json_response(conn, 400)
    end

    test "a malformed device_id is a bounded 400, not a 500", %{conn: conn} do
      client = oauth_application_fixture()

      conn =
        post(conn, ~p"/oauth/device/code", %{
          "client_id" => client.uid,
          "device_id" => "qa-device-grant-test-device"
        })

      assert %{"error" => "invalid_request"} = json_response(conn, 400)
    end
  end

  describe "GET /oauth/device" do
    test "redirects to login when unauthenticated", %{conn: conn} do
      conn = get(conn, ~p"/oauth/device")

      assert redirected_to(conn) == ~p"/users/log-in"
    end

    test "shows the code-entry form when authenticated", %{conn: conn} do
      conn =
        conn
        |> log_in_user(user_fixture())
        |> get(~p"/oauth/device")

      assert html_response(conn, 200) =~ "Connect a device"
    end
  end

  test "device token lists only its user's projects across accounts" do
    user = user_fixture()
    first_account = account_with_owner_fixture(user)
    second_account = account_with_owner_fixture(user)
    other_user = user_fixture()
    other_account = account_with_owner_fixture(other_user)
    first = project_fixture(user_scope_fixture(user, first_account), %{name: "First"})
    second = project_fixture(user_scope_fixture(user, second_account), %{name: "Second"})
    foreign = project_fixture(user_scope_fixture(other_user, other_account), %{name: "Foreign"})
    assert is_nil(CodeMySpec.UserPreferences.scope_for(user).active_account_id)

    client = oauth_application_fixture()
    {:ok, grant} = CodeMySpec.Oauth.request_device_code(client.uid, Ecto.UUID.generate())
    assert {:ok, _} = CodeMySpec.Oauth.decide_device_grant(grant, user, :approve)

    poll =
      post(build_conn(), ~p"/oauth/token", %{
        "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
        "device_code" => grant.device_code,
        "client_id" => client.uid
      })

    assert %{"access_token" => token} = json_response(poll, 200)

    response =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> get(~p"/api/projects")

    assert %{"projects" => projects} = json_response(response, 200)
    assert Enum.sort(Enum.map(projects, & &1["id"])) == Enum.sort([first.id, second.id])
    refute Enum.any?(projects, &(&1["id"] == foreign.id))
  end

  describe "the full flow" do
    setup do
      client = oauth_application_fixture()
      {:ok, grant} = CodeMySpec.Oauth.request_device_code(client.uid, Ecto.UUID.generate())
      %{client: client, grant: grant, user: user_fixture()}
    end

    test "approving the confirm page lets the device's poll succeed", %{
      conn: conn,
      client: client,
      grant: grant,
      user: user
    } do
      conn = log_in_user(conn, user)

      show_conn = post(conn, ~p"/oauth/device", %{"user_code" => grant.user_code})
      assert html_response(show_conn, 200) =~ client.name

      decide_conn =
        post(conn, ~p"/oauth/device/decide", %{
          "device_code" => grant.device_code,
          "decision" => "approve"
        })

      assert html_response(decide_conn, 200) =~ "Device connected"

      poll_conn =
        post(build_conn(), ~p"/oauth/token", %{
          "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
          "device_code" => grant.device_code,
          "client_id" => client.uid
        })

      assert %{"access_token" => token, "token_type" => "Bearer"} = json_response(poll_conn, 200)
      assert is_binary(token)
    end

    test "the minted token carries a refresh_token that itself works", %{
      conn: conn,
      client: client,
      grant: grant,
      user: user
    } do
      conn = log_in_user(conn, user)

      post(conn, ~p"/oauth/device/decide", %{
        "device_code" => grant.device_code,
        "decision" => "approve"
      })

      poll_conn =
        post(build_conn(), ~p"/oauth/token", %{
          "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
          "device_code" => grant.device_code,
          "client_id" => client.uid
        })

      assert %{"refresh_token" => refresh_token} = json_response(poll_conn, 200)
      refute is_nil(refresh_token)

      refresh_conn =
        post(build_conn(), ~p"/oauth/token", %{
          "grant_type" => "refresh_token",
          "refresh_token" => refresh_token,
          "client_id" => client.uid,
          "client_secret" => client.secret
        })

      assert %{"access_token" => new_token} = json_response(refresh_conn, 200)
      refute is_nil(new_token)
    end

    test "a device_code is single-use: a second poll after approval is refused", %{
      conn: conn,
      client: client,
      grant: grant,
      user: user
    } do
      conn = log_in_user(conn, user)

      post(conn, ~p"/oauth/device/decide", %{
        "device_code" => grant.device_code,
        "decision" => "approve"
      })

      first_poll =
        post(build_conn(), ~p"/oauth/token", %{
          "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
          "device_code" => grant.device_code,
          "client_id" => client.uid
        })

      assert %{"access_token" => _} = json_response(first_poll, 200)

      second_poll =
        post(build_conn(), ~p"/oauth/token", %{
          "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
          "device_code" => grant.device_code,
          "client_id" => client.uid
        })

      assert %{"error" => "invalid_grant"} = json_response(second_poll, 400)
    end

    test "denying the confirm page leaves the poll refused", %{
      conn: conn,
      client: client,
      grant: grant,
      user: user
    } do
      conn = log_in_user(conn, user)

      decide_conn =
        post(conn, ~p"/oauth/device/decide", %{
          "device_code" => grant.device_code,
          "decision" => "deny"
        })

      assert html_response(decide_conn, 200) =~ "not connected"

      poll_conn =
        post(build_conn(), ~p"/oauth/token", %{
          "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
          "device_code" => grant.device_code,
          "client_id" => client.uid
        })

      assert %{"error" => "access_denied"} = json_response(poll_conn, 400)
    end

    test "polling before anyone decides answers authorization_pending", %{
      client: client,
      grant: grant
    } do
      poll_conn =
        post(build_conn(), ~p"/oauth/token", %{
          "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
          "device_code" => grant.device_code,
          "client_id" => client.uid
        })

      assert %{"error" => "authorization_pending"} = json_response(poll_conn, 400)
    end

    test "an unknown user_code shows an error rather than someone else's grant", %{
      conn: conn,
      user: user
    } do
      conn =
        conn
        |> log_in_user(user)
        |> post(~p"/oauth/device", %{"user_code" => "ZZZZ-ZZZZ"})

      assert html_response(conn, 200) =~ "was not found"
    end
  end

  describe "polling an unknown device_code" do
    test "answers invalid_grant", %{conn: conn} do
      client = oauth_application_fixture()

      conn =
        post(conn, ~p"/oauth/token", %{
          "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
          "device_code" => "no-such-code",
          "client_id" => client.uid
        })

      assert %{"error" => "invalid_grant"} = json_response(conn, 400)
    end
  end
end
