defmodule CodeMySpecWeb.OauthTimingConfigTest do
  use CodeMySpecTest.ConnCase, async: false

  import CodeMySpec.OauthFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Oauth

  setup do
    grant_config = Application.fetch_env!(:code_my_spec, Oauth)
    provider_config = Application.fetch_env!(:code_my_spec, ExOauth2Provider)

    on_exit(fn ->
      Application.put_env(:code_my_spec, Oauth, grant_config)
      Application.put_env(:code_my_spec, ExOauth2Provider, provider_config)
    end)

    %{client: oauth_application_fixture(), provider_config: provider_config}
  end

  test "HTTP device grants use configured TTL and polling interval", %{conn: conn, client: client} do
    Application.put_env(:code_my_spec, Oauth, ttl_seconds: 12, interval: 1)

    response =
      conn
      |> post(~p"/oauth/device/code", %{"client_id" => client.uid})
      |> json_response(200)

    assert response["interval"] == 1
    assert response["expires_in"] in 11..12

    assert {:error, :authorization_pending} =
             Oauth.poll_device_grant(response["device_code"], client.uid)

    assert {:ok, overridden} =
             Oauth.request_device_code(client.uid, nil, ttl_seconds: 30, interval: 2)

    assert overridden.interval == 2
    assert DateTime.diff(overridden.expires_at, DateTime.utc_now()) in 29..30
  end

  test "zero TTL exercises expiry without changing the grant record", %{
    conn: conn,
    client: client
  } do
    Application.put_env(:code_my_spec, Oauth, ttl_seconds: 0, interval: 1)

    response =
      conn
      |> post(~p"/oauth/device/code", %{"client_id" => client.uid})
      |> json_response(200)

    assert {:error, :expired_token} =
             Oauth.poll_device_grant(response["device_code"], client.uid)
  end

  test "configured token lifetime applies to device approval and refresh", ctx do
    Application.put_env(
      :code_my_spec,
      ExOauth2Provider,
      Keyword.put(ctx.provider_config, :access_token_expires_in, 12)
    )

    {:ok, grant} = Oauth.request_device_code(ctx.client.uid, nil)
    {:ok, _approved} = Oauth.decide_device_grant(grant, user_fixture(), :approve)

    token =
      ctx.conn
      |> post(~p"/oauth/token", %{
        "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
        "client_id" => ctx.client.uid,
        "device_code" => grant.device_code
      })
      |> json_response(200)

    assert token["expires_in"] == 12
    assert is_binary(token["refresh_token"])

    refreshed =
      ctx.conn
      |> recycle()
      |> post(~p"/oauth/token", %{
        "grant_type" => "refresh_token",
        "client_id" => ctx.client.uid,
        "client_secret" => ctx.client.secret,
        "refresh_token" => token["refresh_token"]
      })
      |> json_response(200)

    assert refreshed["expires_in"] == 12
    assert is_binary(refreshed["access_token"])
  end
end
