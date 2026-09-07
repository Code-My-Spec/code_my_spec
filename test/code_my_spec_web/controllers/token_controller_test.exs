defmodule CodeMySpecWeb.TokenControllerTest do
  use CodeMySpecTest.ConnCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AppTokens
  alias CodeMySpecWeb.Plugs.AppToken

  setup %{conn: conn} do
    scope = full_scope_fixture()
    {:ok, project} = AppTokens.put_refresh_secret(scope.active_project, "the-refresh-secret")

    %{conn: put_req_header(conn, "content-type", "application/json"), project: project}
  end

  describe "POST /api/token" do
    test "exchanges a refresh secret for a token and its lifetime", %{conn: conn} do
      conn = post(conn, "/api/token", %{"refresh_secret" => "the-refresh-secret"})
      body = json_response(conn, 200)

      assert is_binary(body["access_token"]) and body["access_token"] != ""
      assert is_integer(body["expires_in"]) and body["expires_in"] > 0
    end

    test "refuses an unknown secret without saying why it failed", %{conn: conn} do
      conn = post(conn, "/api/token", %{"refresh_secret" => "wrong"})
      body = json_response(conn, 401)

      # One refusal on purpose: distinguishing "no such secret" from "wrong
      # secret" tells an unauthenticated caller which half to keep guessing.
      assert body["reason"] == "invalid"
    end

    test "a request without a secret is a bad request, not an auth failure", %{conn: conn} do
      conn = post(conn, "/api/token", %{})

      assert json_response(conn, 400)["error"] == "invalid_request"
    end
  end

  describe "the exchanged token authenticates, the refresh secret does not" do
    setup %{conn: conn} do
      body =
        conn
        |> post("/api/token", %{"refresh_secret" => "the-refresh-secret"})
        |> json_response(200)

      %{token: body["access_token"]}
    end

    test "a valid token is accepted by the plug", %{conn: conn, token: token, project: project} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> AppToken.call([])

      refute conn.halted
      assert conn.assigns.app_token_project_id == project.id
    end

    # The property story 971 actually claims: what the deployed app holds
    # opens none of the surfaces. If this were accepted, the exchange would
    # be decoration (criteria 8045, 8046).
    test "the refresh secret is refused as a bearer credential", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer the-refresh-secret")
        |> AppToken.call([])

      assert conn.halted
      assert json_response(conn, 401)["reason"] == "invalid"
    end

    test "no credential at all is refused", %{conn: conn} do
      conn = AppToken.call(conn, [])

      assert conn.halted
      assert json_response(conn, 401)["reason"] == "invalid"
    end

    # Criterion 8023: the refusal has to distinguish "renew" from "stop".
    test "an aged-out token is refused with reason expired", %{conn: conn, project: project} do
      old =
        Phoenix.Token.sign(
          Application.get_env(:code_my_spec, CodeMySpecWeb.Endpoint)[:secret_key_base],
          "app access token",
          project.id,
          signed_at: System.system_time(:second) - AppTokens.max_age() - 60
        )

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{old}")
        |> AppToken.call([])

      assert conn.halted
      assert json_response(conn, 401)["reason"] == "expired"
    end
  end
end
