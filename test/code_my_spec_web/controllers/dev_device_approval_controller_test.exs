defmodule CodeMySpecWeb.DevDeviceApprovalControllerTest do
  use CodeMySpecTest.ConnCase, async: true

  import CodeMySpec.OauthFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.{Oauth, Users}

  test "password-authenticated dev approval makes the normal device poll succeed" do
    password = "qa-device-approval-password"
    user = user_fixture()

    {:ok, {user, _}} =
      Users.update_user_password(user, %{
        password: password,
        password_confirmation: password
      })

    client = oauth_application_fixture()
    {:ok, grant} = Oauth.request_device_code(client.uid, Ecto.UUID.generate())
    params = %{email: user.email, password: password, user_code: grant.user_code}

    assert %{"approved" => true} =
             build_conn() |> post("/dev/device-approvals", params) |> json_response(200)

    assert %{"access_token" => token} =
             build_conn()
             |> post("/oauth/token", %{
               grant_type: "urn:ietf:params:oauth:grant-type:device_code",
               device_code: grant.device_code,
               client_id: client.uid
             })
             |> json_response(200)

    assert is_binary(token)

    assert %{"error" => _} =
             build_conn() |> post("/dev/device-approvals", params) |> json_response(422)
  end

  test "wrong password and unknown code cannot approve a grant" do
    password = "qa-device-approval-password"
    user = user_fixture()

    {:ok, {user, _}} =
      Users.update_user_password(user, %{
        password: password,
        password_confirmation: password
      })

    client = oauth_application_fixture()
    {:ok, grant} = Oauth.request_device_code(client.uid, Ecto.UUID.generate())
    params = %{email: user.email, password: password, user_code: grant.user_code}

    assert %{"error" => _} =
             build_conn()
             |> post("/dev/device-approvals", %{params | password: "wrong-password"})
             |> json_response(422)

    assert %{"error" => _} =
             build_conn()
             |> post("/dev/device-approvals", %{params | user_code: "ZZZZ-ZZZZ"})
             |> json_response(422)

    refute Oauth.get_device_grant_by_device_code(grant.device_code)
           |> CodeMySpec.Oauth.DeviceGrant.approved?()
  end
end
