defmodule CodeMySpecWeb.UserLive.CheckEmailTest do
  use CodeMySpecTest.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CodeMySpec.UsersFixtures
  import Swoosh.TestAssertions

  describe "mount" do
    test "renders the check-email screen with the submitted email", %{conn: conn} do
      email = "pending@example.com"
      {:ok, _lv, html} = live(conn, ~p"/users/check-email?email=#{email}")

      assert html =~ "Check your email"
      assert html =~ "We sent a login link to"
      assert html =~ email
      assert html =~ "Wrong email?"
    end

    test "mounts the analytics hook that fires registration_email_sent", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/check-email?email=foo@example.com")

      assert html =~ ~s|id="check-email-page"|
      assert html =~ ~s|phx-hook=|
      assert html =~ "RegistrationEmailSent"
    end

    test "Wrong email? link navigates back to /users/register", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/check-email?email=foo@example.com")

      assert lv
             |> element("a", "Wrong email?")
             |> render_click()
             |> follow_redirect(conn, ~p"/users/register")
    end

    test "redirects to /users/register when no email param is provided", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/users/register"}}} =
               live(conn, ~p"/users/check-email")
    end

    test "redirects to /users/register when email param is blank", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/users/register"}}} =
               live(conn, ~p"/users/check-email?email=")
    end
  end

  describe "resend button" do
    test "sends a new magic link when the email matches a registered user", %{conn: conn} do
      user = unconfirmed_user_fixture()
      {:ok, lv, _html} = live(conn, ~p"/users/check-email?email=#{user.email}")

      lv |> element("#resend-button") |> render_click()

      assert_email_sent(fn email ->
        assert email.subject == "Your CodeMySpec login link"
        assert {_, to_addr} = hd(email.to)
        assert to_addr == user.email
      end)
    end

    test "does not leak account existence for unknown emails", %{conn: conn} do
      unknown = "nobody-#{System.unique_integer([:positive])}@example.com"
      {:ok, lv, _html} = live(conn, ~p"/users/check-email?email=#{unknown}")

      html = lv |> element("#resend-button") |> render_click()

      assert html =~ "Check your email"
      refute html =~ "not found"
      refute html =~ "does not exist"
      assert_no_email_sent()
    end

    test "is disabled with a countdown immediately after clicking resend", %{conn: conn} do
      user = unconfirmed_user_fixture()
      {:ok, lv, _html} = live(conn, ~p"/users/check-email?email=#{user.email}")

      html = lv |> element("#resend-button") |> render_click()

      assert html =~ "disabled"
      assert html =~ ~r/Resend \(\d+s\)/
    end

    test "a disabled-button click during cooldown does not send another email", %{conn: conn} do
      user = unconfirmed_user_fixture()
      {:ok, lv, _html} = live(conn, ~p"/users/check-email?email=#{user.email}")

      lv |> element("#resend-button") |> render_click()
      assert_email_sent()

      # Bypass the client-side disabled attribute by pushing the event directly.
      render_click(lv, "resend", %{})

      assert_no_email_sent()
    end
  end
end
