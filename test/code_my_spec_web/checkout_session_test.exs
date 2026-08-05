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

  # The hook pushes exactly this, with an empty payload, once Stripe's
  # confirmPayment resolves without an error. Everything downstream of the
  # card is this event, so this is the whole redirect path minus the iframe.
  test "confirming a payment sends the buyer into the product", %{conn: conn} do
    user = user_fixture()
    account = account_fixture()
    member_fixture(user, account, :owner)

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live_isolated(CodeMySpecWeb.CheckoutLive)

    assert {:error, {:redirect, %{to: "/app"}}} = render_hook(view, "payment_confirmed", %{})
  end
end
