defmodule CodeMySpecWeb.IntakeResetControllerTest do
  use CodeMySpecTest.ConnCase, async: true

  import CodeMySpec.UsersFixtures

  describe "POST /build/reset" do
    test "clears the intake token, so the next visit starts a fresh plan", %{conn: conn} do
      conn = get(conn, ~p"/build/procedural")
      token = get_session(conn, "intake_token")
      assert token

      conn = post(conn, ~p"/build/reset")

      assert redirected_to(conn) == ~p"/build/procedural"
      refute get_session(conn, "intake_token") == token
    end

    test "logs a signed-in visitor out too — unlike log-out, this does not carry the plan across",
         %{conn: conn} do
      conn = conn |> log_in_user(user_fixture()) |> post(~p"/build/reset")

      assert redirected_to(conn) == ~p"/build/procedural"
      refute get_session(conn, :user_token)
    end

    test "succeeds even with no session to clear", %{conn: conn} do
      conn = post(conn, ~p"/build/reset")

      assert redirected_to(conn) == ~p"/build/procedural"
    end
  end
end
