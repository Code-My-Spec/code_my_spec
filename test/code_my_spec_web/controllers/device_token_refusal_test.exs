defmodule CodeMySpecWeb.DeviceTokenRefusalTest do
  use CodeMySpecTest.ConnCase, async: true

  import CodeMySpec.AccountsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Devices
  alias CodeMySpec.Workspaces.Runner

  setup do
    owner = user_fixture()
    account = account_with_owner_fixture(owner)
    scope = user_scope_fixture(owner, account)

    {:ok, box, token} =
      Devices.add_dev_box(
        scope,
        %{"name" => "cloud-box", "provider" => "claude_code_cloud"},
        Runner.dev_box(:claude_code_cloud)
      )

    %{scope: scope, box: box, token: token}
  end

  test "explains when no Authorization header reached the token route", %{conn: conn} do
    response = conn |> post(~p"/api/devices/token", %{}) |> json_response(401)
    assert response["error"] == "missing_authorization"
    assert response["error_description"] =~ "No Authorization header"
  end

  test "explains a credential that is not a box token", %{conn: conn} do
    response =
      conn
      |> put_req_header("authorization", "Bearer other-token")
      |> post(~p"/api/devices/token", %{})
      |> json_response(401)

    assert response["error"] == "not_box_token"
    assert response["error_description"] =~ "cbt_"
  end

  test "distinguishes a box token this server never issued", %{conn: conn} do
    response =
      conn
      |> put_req_header("authorization", "Bearer cbt_unknown")
      |> post(~p"/api/devices/token", %{})
      |> json_response(401)

    assert response["error"] == "unknown_token"
  end

  test "distinguishes a revoked box token", %{conn: conn, scope: scope, box: box, token: token} do
    assert {:ok, _} = Devices.revoke_dev_box(scope, box.id)

    response =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> post(~p"/api/devices/token", %{})
      |> json_response(401)

    assert response["error"] == "revoked_token"
    assert response["error_description"] =~ "revoked"
  end
end
