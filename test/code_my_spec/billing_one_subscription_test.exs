defmodule CodeMySpec.BillingOneSubscriptionTest do
  @moduledoc """
  One billing subscription per account, always.

  `start_subscription/2` created a subscription unconditionally, so an account
  that changed tier ended up with two live in Stripe. Both charged. Our own data
  looked perfect throughout — a single `stripe_subscription_id`, the right
  `plan` — because the older subscription simply stopped being referenced by
  anything we store, and nothing in the product or in any query against our
  database could surface it.

  Found by story 878's QA driving two real purchases through the Payment Element
  and then asking Stripe directly: `sub_1U5RtI…` (light, $25) and `sub_1U5S2n…`
  (pro, $100) both `status=active`, `cancel_at_period_end=false`, on customer
  `cus_V5d9PRejXYh894` (`27f519dc`).

  The first fix was wrong in a way these tests now cover. It branched on
  `scope.active_account`, a snapshot from page mount, while
  `stripe_subscription_id` is written by a *webhook* after it — so the struct in
  hand at click time is exactly the one that has not heard about the
  subscription. Re-QA reproduced the duplicate in both directions against real
  Stripe while every unit test here passed, because the tests build their own
  account and never hold a stale one (`5a5708a7`).

  These assert on the **requests made to Stripe**, not on return values. The
  broken code returned a perfectly good client secret for its second
  subscription, so anything checking the return passes against it.
  """

  # `async: false` deliberately. This file configures the Stripe client through
  # `Application.put_env`, which is global — and `BillingTest` does the same. Two
  # async files mutating one app env is a race that shows up as either file
  # failing depending on scheduling, which is exactly what it did: each passed
  # alone and one failed when they ran together.
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.AccountsFixtures

  alias CodeMySpec.Accounts
  alias CodeMySpec.Billing

  setup do
    Application.put_env(:code_my_spec, CodeMySpec.Billing.StripeClient,
      secret_key: "sk_test_x",
      plug: {Req.Test, CodeMySpec.Billing.StripeClient}
    )

    Application.put_env(:code_my_spec, CodeMySpec.Billing,
      webhook_secret: "whsec_test",
      light_price_id: "price_light",
      pro_price_id: "price_pro"
    )

    on_exit(fn ->
      Application.delete_env(:code_my_spec, CodeMySpec.Billing.StripeClient)
      Application.delete_env(:code_my_spec, CodeMySpec.Billing)
    end)

    :ok
  end

  # Routed by map lookup rather than `case`, which this project bans in test
  # files — and which is the better shape anyway: `Map.fetch!` raises naming the
  # unexpected path, where a `case` clause would either fall through silently or
  # need a catch-all that hides the surprise.
  #
  # Every request is announced to the test process, including its body, so a
  # test can assert on what was sent and on what was *not*.
  defp stub_routes(routes) do
    test_pid = self()

    Req.Test.stub(CodeMySpec.Billing.StripeClient, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:stripe, conn.method, conn.request_path, body})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(Map.fetch!(routes, conn.request_path)))
    end)
  end

  # Buying writes to the account, so the buyer has to be an owner — same shape
  # as `BillingTest`.
  defp owner_scope do
    user = user_fixture()
    account = account_fixture()
    member_fixture(user, account, :owner)
    user_scope_fixture(user, account)
  end

  defp with_subscription(scope, id) do
    {:ok, account} =
      scope.active_account
      |> Ecto.Changeset.change(stripe_customer_id: "cus_1", stripe_subscription_id: id)
      |> CodeMySpec.Repo.update()

    %{scope | active_account: account}
  end

  defp secret, do: %{"confirmation_secret" => %{"client_secret" => "pi_secret"}}

  defp active(id),
    do: %{
      "id" => id,
      "status" => "active",
      "items" => %{"data" => [%{"id" => "si_1"}]},
      "latest_invoice" => secret()
    }

  describe "an account that already pays" do
    test "has its existing subscription moved, not a second one created" do
      scope = owner_scope() |> with_subscription("sub_existing")

      stub_routes(%{
        "/v1/subscriptions/sub_existing" => active("sub_existing"),
        "/v1/subscriptions" => %{"id" => "sub_new", "latest_invoice" => secret()}
      })

      assert {:ok, %{subscription_id: "sub_existing"}} = Billing.start_subscription(scope, :pro)

      refute_received {:stripe, "POST", "/v1/subscriptions", _},
                      """
                      A second subscription was created. Stripe bills both, and our
                      single stripe_subscription_id keeps only this one — so the
                      older keeps charging with nothing referencing it (27f519dc).
                      """
    end

    # The case the first attempt at this fix shipped broken.
    test "a stale scope does not cause a second subscription" do
      scope = owner_scope() |> with_subscription("sub_existing")

      # What a LiveView actually holds: the account as it was before the webhook
      # landed. The database knows better.
      stale = %{scope | active_account: %{scope.active_account | stripe_subscription_id: nil}}

      stub_routes(%{
        "/v1/subscriptions/sub_existing" => active("sub_existing"),
        "/v1/subscriptions" => %{"id" => "sub_new", "latest_invoice" => secret()}
      })

      assert {:ok, %{subscription_id: "sub_existing"}} = Billing.start_subscription(stale, :pro)

      refute_received {:stripe, "POST", "/v1/subscriptions", _},
                      """
                      The scope's account was stale, so the existing subscription
                      was invisible and a second was created — which is exactly
                      what shipped and what real Stripe caught (5a5708a7). The
                      account has to be reloaded, not taken from the scope.
                      """
    end

    test "the update names the subscription item, not just the price" do
      scope = owner_scope() |> with_subscription("sub_existing")

      stub_routes(%{"/v1/subscriptions/sub_existing" => active("sub_existing")})

      assert {:ok, _} = Billing.start_subscription(scope, :pro)

      assert_received {:stripe, "POST", "/v1/subscriptions/sub_existing", body}

      assert body =~ "items%5B0%5D%5Bid%5D=si_1",
             """
             Without the item id Stripe adds a second line to the same
             subscription instead of replacing the first — the same defect one
             level down, and just as invisible from our side. Got: #{body}
             """

      assert body =~ "price_pro", "the new price has to actually be sent. Got: #{body}"
    end
  end

  describe "an account that does not yet pay" do
    test "gets a subscription created" do
      scope = owner_scope()

      stub_routes(%{
        "/v1/customers" => %{"id" => "cus_1"},
        "/v1/subscriptions" => %{"id" => "sub_1", "latest_invoice" => secret()}
      })

      assert {:ok, %{subscription_id: "sub_1"}} = Billing.start_subscription(scope, :light)
      assert_received {:stripe, "POST", "/v1/subscriptions", _}
    end

    test "an abandoned checkout does not block buying" do
      # `incomplete` never charged, so it cannot double-bill and must not stand
      # in the way of a purchase. Stripe expires these on its own.
      scope = owner_scope() |> with_subscription("sub_abandoned")

      stub_routes(%{
        "/v1/subscriptions/sub_abandoned" => %{
          "id" => "sub_abandoned",
          "status" => "incomplete",
          "items" => %{"data" => [%{"id" => "si_x"}]}
        },
        "/v1/subscriptions" => %{"id" => "sub_fresh", "latest_invoice" => secret()}
      })

      assert {:ok, %{subscription_id: "sub_fresh"}} = Billing.start_subscription(scope, :light)
      assert_received {:stripe, "POST", "/v1/subscriptions", _}
    end

    test "a cancelled subscription does not block buying again" do
      scope = owner_scope() |> with_subscription("sub_gone")

      stub_routes(%{
        "/v1/subscriptions/sub_gone" => %{
          "id" => "sub_gone",
          "status" => "canceled",
          "items" => %{"data" => [%{"id" => "si_y"}]}
        },
        "/v1/subscriptions" => %{"id" => "sub_again", "latest_invoice" => secret()}
      })

      assert {:ok, %{subscription_id: "sub_again"}} = Billing.start_subscription(scope, :light)
    end
  end

  test "the account's plan is still not granted here" do
    scope = owner_scope() |> with_subscription("sub_existing")

    stub_routes(%{"/v1/subscriptions/sub_existing" => active("sub_existing")})

    assert {:ok, _} = Billing.start_subscription(scope, :pro)

    assert Accounts.get_account_by_id(scope.active_account.id).plan == :free,
           "the webhook is the only writer of plan — changing tier must not change that"
  end
end
