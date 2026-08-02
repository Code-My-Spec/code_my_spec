defmodule CodeMySpecWeb.WidgetSocketTokenTest do
  use CodeMySpecTest.ConnCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AppTokens

  setup %{conn: conn} do
    scope = full_scope_fixture()
    {:ok, project} = AppTokens.put_refresh_secret(scope.active_project, "the-refresh-secret")
    {:ok, access, _} = AppTokens.exchange("the-refresh-secret")

    %{conn: put_req_header(conn, "content-type", "application/json"), project: project, access: access}
  end

  test "mints a socket token for a holder of an app token", %{conn: conn, access: access} do
    body =
      conn
      |> put_req_header("authorization", "Bearer #{access}")
      |> get("/api/widget/socket_token")
      |> json_response(200)

    assert is_binary(body["socket_token"]) and body["socket_token"] != ""
    assert is_integer(body["expires_in"]) and body["expires_in"] > 0
  end

  test "refuses a caller with no app token", %{conn: conn} do
    assert conn |> get("/api/widget/socket_token") |> json_response(401)
  end

  describe "the two token kinds are not interchangeable" do
    # A socket token reaches a browser; an access token never does. If either
    # opened the other's surface, handing one to a browser would hand over the
    # other's reach too.
    test "a socket token does not open the REST surfaces", %{project: project} do
      {socket_token, _} = AppTokens.issue_socket_token(project)

      assert {:error, :invalid} = AppTokens.verify(socket_token)
    end

    test "an access token does not open a socket", %{access: access} do
      assert {:error, :invalid} = AppTokens.verify_socket_token(access)
    end
  end

  test "the socket accepts a socket token in place of the deploy key", %{project: project} do
    {socket_token, _} = AppTokens.issue_socket_token(project)

    assert {:ok, socket} =
             CodeMySpecWeb.WidgetSocket.connect(
               %{"socket_token" => socket_token, "user_id" => "u1"},
               Phoenix.Socket.__struct__(),
               %{}
             )

    assert socket.assigns.project_id == project.id
    assert socket.assigns.end_user_id == "u1"
  end

  test "the socket refuses an unknown socket token" do
    assert :error =
             CodeMySpecWeb.WidgetSocket.connect(
               %{"socket_token" => "nope"},
               Phoenix.Socket.__struct__(),
               %{}
             )
  end
end
