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
  `cus_V5d9PRejXYh894`. $125/mo for a $100/mo plan, compounding with every
  future upgrade (`27f519dc`).

  These assert on the *requests made to Stripe*, because that is where the
  defect lived. A test that checked the return value would have passed against
  the broken code — it returned a perfectly good client secret for the second
  subscription.
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

  defp stub(fun), do: Req.Test.stub(CodeMySpec.Billing.StripeClient, fun)

  # Buying writes to the account, so the buyer has to be an owner — same shape
  # as `BillingTest`.
  defp owner_scope do
    user = user_fixture()
    account = account_fixture()
    member_fixture(user, account, :owner)
    user_scope_fixture(user, account)
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end

  defp with_subscription(scope, id) do
    {:ok, account} =
      scope.active_account
      |> Ecto.Changeset.change(stripe_customer_id: "cus_1", stripe_subscription_id: id)
      |> CodeMySpec.Repo.update()

    %{scope | active_account: account}
  end

  defp secret, do: %{"confirmation_secret" => %{"client_secret" => "pi_secret"}}

  describe "an account that already pays" do
    # The case the first attempt at this fix shipped broken.
    #
    # `ensure_customer/1` hands back `scope.active_account` — a snapshot from
    # when the page mounted. `stripe_subscription_id` is written by a webhook
    # *after* that, so at click time the struct in hand is precisely the one
    # that has not heard about the subscription. Branching on it created a
    # second subscription every time, in both directions, against real Stripe
    # (`5a5708a7`) while every unit test passed — because the tests built the
    # account themselves and never had a stale one.
    test "a stale scope does not cause a second subscription" do
      scope = owner_scope() |> with_subscription("sub_existing")

      # What a LiveView actually holds: the account as it was before the
      # webhook landed. The database knows better.
      stale = %{scope | active_account: %{scope.active_account | stripe_subscription_id: nil}}

      test_pid = self()

      stub(fn conn ->
        send(test_pid, {:stripe, conn.method, conn.request_path})

        case conn.request_path do
          "/v1/subscriptions/sub_existing" ->
            json(conn, %{"id" => "sub_existing", "status" => "active",
                         "items" => %{"data" => [%{"id" => "si_1"}]},
                         "latest_invoice" => secret()})

          "/v1/subscriptions" ->
            json(conn, %{"id" => "sub_new", "latest_invoice" => secret()})
        end
      end)

      assert {:ok, %{subscription_id: "sub_existing"}} = Billing.start_subscription(stale, :pro)

      refute_received {:stripe, "POST", "/v1/subscriptions"},
                      """
                      The scope's account was stale, so the existing subscription
                      was invisible and a second was created — which is exactly
                      what shipped and what real Stripe caught. The account has
                      to be reloaded, not taken from the scope.
                      """
    end

    test "has its existing subscription moved, not a second one created" do
      scope = owner_scope() |> with_subscription("sub_existing")
      test_pid = self()

      stub(fn conn ->
        send(test_pid, {:stripe, conn.method, conn.request_path})

        case conn.request_path do
          "/v1/subscriptions/sub_existing" ->
            json(conn, %{"id" => "sub_existing", "status" => "active",
                         "items" => %{"data" => [%{"id" => "si_1"}]},
                         "latest_invoice" => secret()})

          "/v1/subscriptions" ->
            json(conn, %{"id" => "sub_new", "latest_invoice" => secret()})
        end
      end)

      assert {:ok, %{subscription_id: "sub_existing"}} = Billing.start_subscription(scope, :pro)

      refute_received {:stripe, "POST", "/v1/subscriptions"},
                      """
                      A second subscription was created. Stripe bills both, and our
                      single stripe_subscription_id keeps only this one — so the
                      older keeps charging with nothing referencing it (27f519dc).
                      """
    end

    test "the update names the subscription item, not just the price" do
      scope = owner_scope() |> with_subscription("sub_existing")
      test_pid = self()

      stub(fn conn ->
        case conn.request_path do
          "/v1/subscriptions/sub_existing" ->
            if conn.method == "POST" do
              {:ok, body, conn} = Plug.Conn.read_body(conn)
              send(test_pid, {:update_body, body})
            end

            json(conn, %{"id" => "sub_existing", "status" => "active",
                         "items" => %{"data" => [%{"id" => "si_1"}]},
                         "latest_invoice" => secret()})
        end
      end)

      assert {:ok, _} = Billing.start_subscription(scope, :pro)

      assert_received {:update_body, body}

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
      test_pid = self()

      stub(fn conn ->
        send(test_pid, {:stripe, conn.request_path})

        case conn.request_path do
          "/v1/customers" -> json(conn, %{"id" => "cus_1"})
          "/v1/subscriptions" -> json(conn, %{"id" => "sub_1", "latest_invoice" => secret()})
        end
      end)

      assert {:ok, %{subscription_id: "sub_1"}} = Billing.start_subscription(scope, :light)
      assert_received {:stripe, "/v1/subscriptions"}
    end

    test "an abandoned checkout does not block buying" do
      # `incomplete` never charged, so it cannot double-bill and must not stand
      # in the way of a purchase. Stripe expires these on its own.
      scope = owner_scope() |> with_subscription("sub_abandoned")
      test_pid = self()

      stub(fn conn ->
        send(test_pid, {:stripe, conn.method, conn.request_path})

        case conn.request_path do
          "/v1/subscriptions/sub_abandoned" ->
            json(conn, %{"id" => "sub_abandoned", "status" => "incomplete",
                         "items" => %{"data" => [%{"id" => "si_x"}]}})

          "/v1/subscriptions" ->
            json(conn, %{"id" => "sub_fresh", "latest_invoice" => secret()})
        end
      end)

      assert {:ok, %{subscription_id: "sub_fresh"}} = Billing.start_subscription(scope, :light)
      assert_received {:stripe, "POST", "/v1/subscriptions"}
    end

    test "a cancelled subscription does not block buying again" do
      scope = owner_scope() |> with_subscription("sub_gone")

      stub(fn conn ->
        case conn.request_path do
          "/v1/subscriptions/sub_gone" ->
            json(conn, %{"id" => "sub_gone", "status" => "canceled",
                         "items" => %{"data" => [%{"id" => "si_y"}]}})

          "/v1/subscriptions" ->
            json(conn, %{"id" => "sub_again", "latest_invoice" => secret()})
        end
      end)

      assert {:ok, %{subscription_id: "sub_again"}} = Billing.start_subscription(scope, :light)
    end
  end

  test "the account's plan is still not granted here" do
    scope = owner_scope() |> with_subscription("sub_existing")

    stub(fn conn ->
      json(conn, %{"id" => "sub_existing", "status" => "active",
                   "items" => %{"data" => [%{"id" => "si_1"}]},
                   "latest_invoice" => secret()})
    end)

    assert {:ok, _} = Billing.start_subscription(scope, :pro)

    assert Accounts.get_account_by_id(scope.active_account.id).plan == :free,
           "the webhook is the only writer of plan — changing tier must not change that"
  end
end
