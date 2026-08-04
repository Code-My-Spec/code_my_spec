defmodule CodeMySpecWeb.CheckoutSessionTest do
  use CodeMySpecTest.ConnCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.AccountsFixtures

  test "a signed-in owner sees tiers to buy, not a sign-in prompt", %{conn: conn} do
    user = user_fixture()
    account = account_fixture()
    member_fixture(user, account, :owner)

    html =
      conn
      |> log_in_user(user)
      |> get(~p"/pricing")
      |> html_response(200)

    refute html =~ "Sign in\nto pick a plan",
           "the nested CheckoutLive is not seeing the session"

    assert html =~ "Light harness"
  end
end
