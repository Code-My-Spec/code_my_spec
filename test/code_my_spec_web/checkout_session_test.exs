defmodule CodeMySpecWeb.CheckoutSessionTest do
  use CodeMySpecTest.ConnCase, async: true

  import Phoenix.LiveViewTest
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

  # The hook pushes exactly this once Stripe confirms the payment. The page
  # reports receipt in place while the webhook decides the account's tier.
  test "confirming a payment reports receipt on the pricing page", %{conn: conn} do
    user = user_fixture()
    account = account_fixture()
    member_fixture(user, account, :owner)

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live_isolated(CodeMySpecWeb.CheckoutLive)

    html = render_hook(view, "payment_confirmed", %{})
    assert html =~ "Payment received. Your plan will be active in a moment."
    assert html =~ ~s(data-test="payment-notice")
  end
end
