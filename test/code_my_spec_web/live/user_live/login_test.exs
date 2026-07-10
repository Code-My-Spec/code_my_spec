defmodule CodeMySpecWeb.UserLive.LoginTest do
  use CodeMySpecTest.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CodeMySpec.UsersFixtures

  describe "login page" do
    test "renders OAuth-primary login page with magic-link secondary", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "Log in"
      # OAuth primary path — same chamfered/glowing treatment as the
      # register page (Story C: OAuth-primary visual hierarchy).
      assert html =~ "Continue with GitHub"
      assert html =~ "Continue with Google"
      # Magic-link is the secondary path, behind a divider.
      assert html =~ "or send a login link"
      assert html =~ "Email me a login link"
      # Story C explicitly drops the password form — its endpoint
      # (POST /users/log-in) is covered by user_session_controller_test.
      refute html =~ "login_form_password"
    end

    test "tags OAuth buttons with login-method data attributes for analytics",
         %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")
      assert html =~ ~s|data-login-method="github"|
      assert html =~ ~s|data-login-method="google"|
    end
  end

  describe "user login - magic link" do
    test "sends magic link email when user exists", %{conn: conn} do
      user = user_fixture()

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      {:ok, _lv, html} =
        form(lv, "#login_form_magic", user: %{email: user.email})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "If your email is in our system"

      assert CodeMySpec.Repo.get_by!(CodeMySpec.Users.UserToken, user_id: user.id).context ==
               "login"
    end

    test "does not disclose if user is registered", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      {:ok, _lv, html} =
        form(lv, "#login_form_magic", user: %{email: "idonotexist@example.com"})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "If your email is in our system"
    end
  end

  describe "login navigation" do
    test "links to the registration page via the Get started link", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      {:ok, _register_live, register_html} =
        lv
        |> element("main a", "Get started")
        |> render_click()
        |> follow_redirect(conn, ~p"/users/register")

      assert register_html =~ "Bring the idea."
    end
  end

  describe "re-authentication (sudo mode)" do
    setup %{conn: conn} do
      user = user_fixture()
      %{user: user, conn: log_in_user(conn, user)}
    end

    test "shows login page with email filled in", %{conn: conn, user: user} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "You need to reauthenticate"
      # Logged-in user sees re-auth subcopy, not the "Don't have an
      # account? Get started" prompt.
      refute html =~ "Don't have an account"
      assert html =~ "Continue with GitHub"
      assert html =~ "Email me a login link"

      assert html =~
               ~s(<input type="email" name="user[email]" id="login_form_magic_email" value="#{user.email}")
    end
  end
end
