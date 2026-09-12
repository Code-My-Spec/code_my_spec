defmodule CodeMySpecWeb.DevSignInControllerTest do
  @moduledoc """
  The door QA uses to get a real session.

  The assertion that matters is not that these return a URL — it is that the URL
  works against the product's own login route. A dev helper that mints its own
  kind of session would let QA pass while real sign-in was broken, which is the
  opposite of what QA is for.
  """

  use CodeMySpecTest.ConnCase, async: true

  import CodeMySpec.UsersFixtures

  describe "POST /dev/sign-in" do
    test "returns a link that actually signs the user in", %{conn: conn} do
      password = "a-long-enough-password-123"
      user = user_fixture()

      {:ok, {user, _}} =
        CodeMySpec.Users.update_user_password(user, %{
          password: password,
          password_confirmation: password
        })

      body =
        conn
        |> post(~p"/dev/sign-in", %{email: user.email, password: password})
        |> json_response(200)

      assert body["email"] == user.email
      assert %URI{path: "/users/log-in/" <> token} = URI.parse(body["sign_in_url"])

      # The real route, the real controller. If this stops working, QA should
      # fail rather than sail past on a bypass of its own.
      signed_in = get(build_conn(), ~p"/users/log-in/#{token}")

      assert redirected_to(signed_in)

      assert get_session(signed_in, :user_token),
             """
             The minted token did not produce a session on the product's own
             login route. A dev sign-in that authenticates differently from the
             real one lets QA pass while sign-in is broken.
             """
    end

    test "a wrong password gets no link", %{conn: conn} do
      user = user_fixture()

      body =
        conn
        |> post(~p"/dev/sign-in", %{email: user.email, password: "not-the-password"})
        |> json_response(422)

      assert body["error"] =~ "no user"
      refute body["sign_in_url"]
    end

    test "missing credentials are refused rather than guessed at", %{conn: conn} do
      body = conn |> post(~p"/dev/sign-in", %{email: "someone@example.com"}) |> json_response(422)

      assert body["error"] =~ "both email and password"
    end
  end

  describe "POST /dev/sign-up" do
    test "mints an account QA can then sign in to", %{conn: conn} do
      email = "qa-#{System.unique_integer([:positive])}@example.com"

      body = conn |> post(~p"/dev/sign-up", %{email: email}) |> json_response(200)

      assert body["email"] == email
      assert body["user_id"]
      assert %URI{path: "/users/log-in/" <> token} = URI.parse(body["sign_in_url"])

      signed_in = get(build_conn(), ~p"/users/log-in/#{token}")
      assert get_session(signed_in, :user_token)
    end

    test "a password is optional, because an account without one is a real state",
         %{conn: conn} do
      email = "qa-#{System.unique_integer([:positive])}@example.com"
      password = "another-long-enough-password"

      assert conn
             |> post(~p"/dev/sign-up", %{email: email, password: password})
             |> json_response(200)

      # And it is the password that was set, so QA can sign in with it later
      # rather than only through the returned link.
      assert CodeMySpec.Users.get_user_by_email_and_password(email, password)
    end

    test "a duplicate email is refused with the reason", %{conn: conn} do
      user = user_fixture()

      body = conn |> post(~p"/dev/sign-up", %{email: user.email}) |> json_response(422)

      assert body["error"] =~ "email"
    end
  end
end
