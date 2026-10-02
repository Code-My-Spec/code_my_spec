defmodule CodeMySpecWeb.UserAuthDesktopTest do
  # Not async: flips the app-wide `:env`, which ExUnit only runs after every
  # async module has finished.
  use CodeMySpecTest.ConnCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Desktop
  alias CodeMySpecWeb.UserAuth
  alias Phoenix.LiveView

  setup %{conn: conn} do
    user = user_fixture(%{email: Desktop.email()})
    %{user: user, conn: init_test_session(conn, %{})}
  end

  describe "under :desktop" do
    setup do
      previous = Application.get_env(:code_my_spec, :env)
      Application.put_env(:code_my_spec, :env, :desktop)
      on_exit(fn -> Application.put_env(:code_my_spec, :env, previous) end)
    end

    test "an anonymous request is the desktop user", %{conn: conn, user: user} do
      conn = UserAuth.fetch_current_scope_for_user(conn, [])
      assert conn.assigns.current_scope.user.id == user.id
    end

    test "LiveViews mount as the desktop user, sudo included", %{user: user} do
      for hook <- [:mount_current_scope, :require_authenticated, :require_sudo_mode] do
        assert {:cont, socket} = UserAuth.on_mount(hook, %{}, %{}, %LiveView.Socket{})
        assert socket.assigns.current_scope.user.id == user.id
      end
    end
  end

  describe "outside :desktop" do
    test "an anonymous request has no user even when the desktop user exists", %{conn: conn} do
      conn = UserAuth.fetch_current_scope_for_user(conn, [])
      assert conn.assigns.current_scope == nil

      socket = %LiveView.Socket{
        endpoint: CodeMySpecWeb.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}}
      }

      assert {:halt, _} = UserAuth.on_mount(:require_authenticated, %{}, %{}, socket)
    end
  end
end
