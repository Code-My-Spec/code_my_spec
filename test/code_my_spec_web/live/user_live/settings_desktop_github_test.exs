defmodule CodeMySpecWeb.UserLive.SettingsDesktopGitHubTest do
  @moduledoc """
  The desktop keeps no client secret, and GitHub's web flow needs one at the
  exchange, so on the desktop GitHub connects by device flow: a code typed at
  github.com/login/device, polled until GitHub answers (bb8bc042).
  """
  # Not async: flips the app-wide `:env`.
  use CodeMySpecTest.ConnCase, async: false

  import CodeMySpec.UsersFixtures
  import Phoenix.LiveViewTest

  alias CodeMySpec.Integrations
  alias CodeMySpec.Integrations.Providers.GitHub.DeviceAuth
  alias CodeMySpec.UserPreferences.DesktopUser

  setup %{conn: conn} do
    user = user_fixture(%{email: DesktopUser.email()})
    previous = Application.get_env(:code_my_spec, :env)
    Application.put_env(:code_my_spec, :env, :desktop)
    on_exit(fn -> Application.put_env(:code_my_spec, :env, previous) end)
    %{conn: init_test_session(conn, %{}), user: user}
  end

  # One response per call, in the order the flow makes them.
  defp expect_next(lv, fun) do
    Req.Test.expect(DeviceAuth, fun)
    Req.Test.allow(DeviceAuth, self(), lv.pid)
  end

  defp start(conn) do
    {:ok, lv, _html} = live(conn, ~p"/app/users/settings")

    expect_next(lv, fn conn ->
      Req.Test.json(conn, %{
        "device_code" => "dev-code",
        "user_code" => "ABCD-1234",
        "verification_uri" => "https://github.com/login/device",
        "interval" => 1
      })
    end)

    html =
      lv
      |> element("button[phx-click='start_device_auth'][phx-value-provider='github']")
      |> render_click()

    {lv, html}
  end

  test "GitHub is a device-code connect, not a redirect link", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/app/users/settings")

    refute html =~ ~s|href="/auth/github"|
    assert html =~ ~s|phx-value-provider="github"|
  end

  test "connecting shows the code and where to type it", %{conn: conn} do
    {_lv, html} = start(conn)

    assert html =~ "ABCD-1234"
    assert html =~ "github.com/login/device"
    assert html =~ "Finish connecting GitHub"
  end

  test "keeps the code up while GitHub is still waiting", %{conn: conn} do
    {lv, _html} = start(conn)

    expect_next(lv, fn conn -> Req.Test.json(conn, %{"error" => "authorization_pending"}) end)
    send(lv.pid, :poll_device_auth)

    assert render(lv) =~ "ABCD-1234"
  end

  test "connects once the human has finished", %{conn: conn, user: user} do
    {lv, _html} = start(conn)

    expect_next(lv, fn conn ->
      Req.Test.json(conn, %{"access_token" => "gho_token", "scope" => "repo,user:email"})
    end)

    expect_next(lv, fn conn ->
      Req.Test.json(conn, %{"id" => 42, "login" => "octo", "email" => nil, "name" => "Octo"})
    end)

    send(lv.pid, :poll_device_auth)
    html = render(lv)

    assert html =~ "GitHub connected"
    refute html =~ "ABCD-1234"

    assert Integrations.connected?(user_scope_fixture(user), :github)
  end
end
