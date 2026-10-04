defmodule CodeMySpecWeb.IntegrationsDesktopTest do
  @moduledoc """
  On the desktop the provider's page opens in the system browser, whose
  cookies are not the window's, so the callback finds its flow by `state`
  (CodeMySpecDesktop.OAuthHandoff) instead of the session.
  """
  # Not async: flips the app-wide `:env`.
  use CodeMySpecTest.ConnCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpecDesktop.{Identity, OAuthHandoff}

  setup %{conn: conn} do
    user_fixture(%{email: Identity.email()})
    previous = Application.get_env(:code_my_spec, :env)
    Application.put_env(:code_my_spec, :env, :desktop)
    on_exit(fn -> Application.put_env(:code_my_spec, :env, previous) end)
    start_supervised!(OAuthHandoff)
    %{conn: init_test_session(conn, %{})}
  end

  test "connecting sends the provider's page to the browser, not the window", %{conn: conn} do
    conn = get(conn, ~p"/auth/github")

    assert redirected_to(conn) == ~p"/app/users/settings"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "in your browser"
    refute get_session(conn, :oauth_session_params)
  end

  test "the browser's callback, with no session, finds the flow by its state", %{conn: conn} do
    :ok =
      OAuthHandoff.park(%{
        session_params: %{state: "s1"},
        provider: :github,
        flow: :integration
      })

    conn = get(conn, ~p"/auth/github/callback?state=s1&error=access_denied")

    assert redirected_to(conn) == ~p"/app/users/settings"
    assert Phoenix.Flash.get(conn.assigns.flash, :error)
    assert OAuthHandoff.claim("s1") == :error
  end
end
