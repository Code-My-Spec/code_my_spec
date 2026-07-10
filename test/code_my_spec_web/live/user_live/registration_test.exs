defmodule CodeMySpecWeb.UserLive.RegistrationTest do
  use CodeMySpecTest.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CodeMySpec.UsersFixtures

  describe "Registration page" do
    test "renders the builder-focused headline", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")

      assert html =~ "Bring the idea."
      assert html =~ "Start building."
      assert html =~ "Log in"
    end

    test "renders the free / no-credit-card reassurance", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")
      assert html =~ "Free to start, just an email."
      assert html =~ "No password, no company, no credit card."
    end

    test "promotes the free-to-build tagline directly under the headline", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")
      assert html =~ "Free to build — you and the model, shaping real software together."
      assert html =~ "Real software, not a prototype."
    end

    test "renders the BYO-keys differentiator line", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")
      assert html =~ "Bring your own AI keys; we never mark them up."
    end

    test "renders the MetricFlow proof line linking to the case study", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")

      assert html =~ "John built and runs MetricFlow"
      assert html =~ "Read the case study"
      assert html =~ ~s|href="/case-studies/metric-flow"|
    end

    test "tags OAuth buttons with registration-method data attributes for analytics",
         %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")

      assert html =~ ~s|data-registration-method="github"|
      assert html =~ ~s|data-registration-method="google"|
    end

    test "mounts the analytics hook that fires view_register_page and registration_form_start",
         %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")

      assert html =~ ~s|id="register-page"|
      assert html =~ ~s|phx-hook=|
      assert html =~ "ViewRegisterPage"
    end

    test "redirects if already logged in", %{conn: conn} do
      result =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/register")
        |> follow_redirect(conn, ~p"/")

      assert {:ok, _conn} = result
    end

    test "renders errors for invalid data", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      result =
        lv
        |> element("#registration_form")
        |> render_change(user: %{"email" => "with spaces"})

      assert result =~ "Bring the idea."
      assert result =~ "must have the @ sign and no spaces"
    end
  end

  describe "register user" do
    test "creates account and redirects to check-email screen", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      email = unique_user_email()
      form = form(lv, "#registration_form", user: valid_user_attributes(email: email))

      {:ok, _lv, html} =
        render_submit(form)
        |> follow_redirect(conn, ~p"/users/check-email?email=#{email}")

      assert html =~ "Check your email"
      assert html =~ email
    end

    test "renders errors for duplicated email", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      user = user_fixture(%{email: "test@email.com"})

      result =
        lv
        |> form("#registration_form",
          user: %{"email" => user.email}
        )
        |> render_submit()

      assert result =~ "has already been taken"
    end
  end

  describe "registration navigation" do
    test "redirects to login page when the Log in button is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      {:ok, _login_live, login_html} =
        lv
        |> element("main a", "Log in")
        |> render_click()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert login_html =~ "Log in"
    end
  end
end
