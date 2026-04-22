defmodule CodeMySpec.Users.UserNotifierTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.Users.UserNotifier

  import CodeMySpec.UsersFixtures

  describe "deliver_login_instructions/2 for unconfirmed users (confirmation)" do
    test "uses the CRO subject line" do
      user = unconfirmed_user_fixture()
      {:ok, email} = UserNotifier.deliver_login_instructions(user, "https://example.com/confirm")
      assert email.subject == "Your CodeMySpec login link"
    end

    test "body welcomes the user and announces 60-minute expiry" do
      user = unconfirmed_user_fixture()
      url = "https://example.com/confirm/token-123"

      {:ok, email} = UserNotifier.deliver_login_instructions(user, url)

      assert email.text_body =~ "Welcome to CodeMySpec."
      assert email.text_body =~ "confirm your account"
      assert email.text_body =~ url
      assert email.text_body =~ "This link expires in 60 minutes."
      assert email.text_body =~ "-- John"
    end

    test "body does not leak the user's email address" do
      user = unconfirmed_user_fixture()
      {:ok, email} = UserNotifier.deliver_login_instructions(user, "https://example.com/x")
      refute email.text_body =~ user.email
    end
  end

  describe "deliver_login_instructions/2 for confirmed users (magic link)" do
    test "uses the CRO subject line" do
      user = user_fixture()
      {:ok, email} = UserNotifier.deliver_login_instructions(user, "https://example.com/login")
      assert email.subject == "Your CodeMySpec login link"
    end

    test "body is the concise returning-user copy" do
      user = user_fixture()
      url = "https://example.com/login/token-xyz"

      {:ok, email} = UserNotifier.deliver_login_instructions(user, url)

      assert email.text_body =~ "Here's your login link:"
      assert email.text_body =~ url
      assert email.text_body =~ "This link expires in 60 minutes."
      refute email.text_body =~ "Welcome to CodeMySpec."
    end
  end
end
