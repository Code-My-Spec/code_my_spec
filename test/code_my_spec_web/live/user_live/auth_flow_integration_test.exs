defmodule CodeMySpecWeb.UserLive.AuthFlowIntegrationTest do
  @moduledoc """
  End-to-end tests for the signup and login flows. Exercises the real
  registration form, the real confirmation email, and the real magic
  link URL — no token-extraction shortcuts.

  These tests are the guardrail for any future CRO / copy / expiry
  changes to registration, email notifications, or the magic-link
  controller: if one of them starts asserting the flow is broken,
  the deployed signup is broken.
  """

  use CodeMySpecTest.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Users

  @magic_link_url_regex ~r|https?://[^\s]+/users/log-in/[A-Za-z0-9_\-]+|

  describe "new user signup end-to-end" do
    test "register → check-email screen → confirmation email → magic link → authenticated session",
         %{conn: conn} do
      email = unique_user_email()

      # Step 1 — Submit the registration form.
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      {:ok, _check_lv, check_html} =
        lv
        |> form("#registration_form", user: valid_user_attributes(email: email))
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/check-email?email=#{email}")

      assert check_html =~ "Check your email"
      assert check_html =~ email

      # Step 2 — Capture the real confirmation email and extract the magic-link URL.
      {url, token} = capture_magic_link!(to: email, flavor: :confirmation)

      # Step 3 — Visit the magic-link URL in a fresh conn (as the user would from their inbox).
      fresh_conn = build_conn()
      {:ok, confirm_lv, confirm_html} = live(fresh_conn, url_path(url))

      assert confirm_html =~ "Welcome #{email}"
      assert confirm_html =~ "Confirm and stay logged in"

      # Step 4 — Submit the confirmation form (stay-logged-in variant) and follow
      #          the trigger-action POST to /users/log-in?_action=confirmed.
      form = form(confirm_lv, "#confirmation_form", %{"user" => %{"token" => token}})

      render_submit(form)
      final_conn = follow_trigger_action(form, fresh_conn)

      # Step 5 — Assert we are actually logged in and routed to onboarding.
      assert get_session(final_conn, :user_token)
      assert redirected_to(final_conn) == ~p"/app/onboarding"

      # Sanity: the user is now confirmed in the DB.
      user = Users.get_user_by_email(email)
      assert user.confirmed_at
    end

    test "the resend button on the check-email screen issues a fresh usable magic link",
         %{conn: conn} do
      email = unique_user_email()

      {:ok, lv, _} = live(conn, ~p"/users/register")

      {:ok, check_lv, _} =
        lv
        |> form("#registration_form", user: valid_user_attributes(email: email))
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/check-email?email=#{email}")

      # Drain the first email so the resend assertion only sees the resent one.
      assert_receive {:email, %Swoosh.Email{}}, 500

      check_lv |> element("#resend-button") |> render_click()

      {url, token} = capture_magic_link!(to: email, flavor: :confirmation)

      # The resent link must actually authenticate.
      fresh_conn = build_conn()
      {:ok, confirm_lv, _} = live(fresh_conn, url_path(url))

      form =
        form(confirm_lv, "#confirmation_form", %{"user" => %{"token" => token}})

      render_submit(form)
      final_conn = follow_trigger_action(form, fresh_conn)

      assert get_session(final_conn, :user_token)
      assert redirected_to(final_conn) == ~p"/app/onboarding"
    end
  end

  describe "returning-user login end-to-end" do
    test "log-in form → magic-link email → link → authenticated session", %{conn: conn} do
      user = user_fixture()
      # user_fixture sends a login email internally; drain it so assert_receive
      # below picks up the email the production flow sends.
      drain_emails()

      {:ok, lv, _} = live(conn, ~p"/users/log-in")

      {:ok, _login_lv, html} =
        lv
        |> form("#login_form_magic", user: %{email: user.email})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "If your email is in our system"

      {url, token} = capture_magic_link!(to: user.email, flavor: :magic_link)

      fresh_conn = build_conn()
      {:ok, login_lv, login_html} = live(fresh_conn, url_path(url))

      # Confirmed users see the login form (no confirm-and-stay copy).
      refute login_html =~ "Confirm my account"
      assert login_html =~ "Log in"

      form =
        form(login_lv, "#login_form", %{"user" => %{"token" => token}})

      render_submit(form)
      final_conn = follow_trigger_action(form, fresh_conn)

      assert get_session(final_conn, :user_token)
      assert Phoenix.Flash.get(final_conn.assigns.flash, :info) =~ "Welcome back!"
    end
  end

  describe "magic link expiry" do
    test "token issued 61 minutes ago no longer authenticates", %{conn: conn} do
      user = user_fixture()
      drain_emails()

      {:ok, lv, _} = live(conn, ~p"/users/log-in")

      lv
      |> form("#login_form_magic", user: %{email: user.email})
      |> render_submit()
      |> follow_redirect(conn, ~p"/users/log-in")

      {url, _token} = capture_magic_link!(to: user.email, flavor: :magic_link)

      # Age every token in the DB past the 60-minute expiry.
      expired_at = DateTime.utc_now(:second) |> DateTime.add(-61, :minute)

      {_, nil} =
        CodeMySpec.Repo.update_all(
          CodeMySpec.Users.UserToken,
          set: [inserted_at: expired_at]
        )

      {:ok, _lv, html} =
        live(build_conn(), url_path(url))
        |> follow_redirect(build_conn(), ~p"/users/log-in")

      assert html =~ "Magic link is invalid or it has expired"
    end
  end

  # Helpers --------------------------------------------------------------------

  defp capture_magic_link!(to: email, flavor: flavor) do
    expected_subject =
      case flavor do
        :confirmation -> "Your CodeMySpec login link"
        :magic_link -> "Your CodeMySpec login link"
      end

    assert_receive {:email, %Swoosh.Email{} = sent}, 500
    assert sent.subject == expected_subject
    assert {_, ^email} = hd(sent.to)

    [url] = Regex.run(@magic_link_url_regex, sent.text_body)
    "/users/log-in/" <> token = URI.parse(url).path
    {url, token}
  end

  defp url_path(url), do: URI.parse(url).path

  defp drain_emails do
    receive do
      {:email, _} -> drain_emails()
    after
      0 -> :ok
    end
  end
end
