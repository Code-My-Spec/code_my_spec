defmodule CodeMySpec.BillingTest do
  @moduledoc """
  Story 993 — buying a plan puts the account on it.

  The Stripe API is intercepted with `Req.Test`. What is deliberately NOT
  faked is the dedup row: redelivery protection is a real unique index doing
  real work, and a test that stubbed it would prove nothing.
  """

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

  # Buying a plan writes to the account, which requires manage_account — so the
  # buyer has to be an owner. A plain member cannot put an account on a paid
  # tier, which is the intended behaviour and worth pinning here.
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

  defp reload(account), do: Accounts.get_account_by_id(account.id)

  defp event(type, account_id, extra \\ %{}) do
    %{
      "id" => "evt_#{System.unique_integer([:positive])}",
      "type" => type,
      "data" => %{
        "object" => Map.merge(%{"metadata" => %{"account_id" => account_id}}, extra)
      }
    }
  end

  describe "start_subscription/2" do
    test "returns the secret the browser confirms, and grants nothing yet" do
      scope = owner_scope()

      stub(fn conn ->
        case conn.request_path do
          "/v1/customers" -> json(conn, %{"id" => "cus_1"})
          "/v1/subscriptions" -> json(conn, %{
            "id" => "sub_1",
            "latest_invoice" => %{"confirmation_secret" => %{"client_secret" => "pi_1_secret"}}
          })
        end
      end)

      assert {:ok, %{client_secret: "pi_1_secret", subscription_id: "sub_1"}} =
               Billing.start_subscription(scope, :light)

      # The tier flips on the webhook, never here.
      assert reload(scope.active_account).plan == :free
    end

    test "a subscription with no confirmation secret is an error, not a silent pass" do
      scope = owner_scope()

      stub(fn conn ->
        case conn.request_path do
          "/v1/customers" -> json(conn, %{"id" => "cus_1"})
          "/v1/subscriptions" -> json(conn, %{"id" => "sub_1", "latest_invoice" => %{}})
        end
      end)

      assert {:error, :no_client_secret} = Billing.start_subscription(scope, :light)
    end

    test "the customer is created once and reused" do
      scope = owner_scope()
      test_pid = self()

      stub(fn conn ->
        case conn.request_path do
          "/v1/customers" ->
            send(test_pid, :customer_created)
            json(conn, %{"id" => "cus_1"})

          "/v1/subscriptions" ->
            json(conn, %{
              "id" => "sub_1",
              "latest_invoice" => %{"confirmation_secret" => %{"client_secret" => "s"}}
            })
        end
      end)

      {:ok, _} = Billing.start_subscription(scope, :light)
      assert_received :customer_created

      scope = %{scope | active_account: reload(scope.active_account)}
      {:ok, _} = Billing.start_subscription(scope, :pro)

      refute_received :customer_created
    end
  end

  describe "apply_event/1 — the only writer of the plan" do
    test "a succeeded payment puts the account on the tier it paid for" do
      scope = owner_scope()
      account = scope.active_account

      :ok =
        Billing.apply_event(
          event("invoice.payment_succeeded", account.id, %{
            "metadata" => %{"account_id" => account.id, "tier" => "pro"}
          })
        )

      assert reload(account).plan == :pro
    end

    # The shape below is copied from a real invoice.payment_succeeded Stripe
    # delivered for a real charge — no top-level metadata, everything nested
    # under parent.subscription_details, and no top-level `subscription` at
    # all. A hand-made event agreed with the code and disagreed with Stripe,
    # which is how a payment once got taken and granted nothing.
    test "a real invoice grants the tier and records the subscription that paid" do
      scope = owner_scope()
      account = scope.active_account

      real_invoice = %{
        "id" => "evt_1U18kBIn2rXVSrRDObMlVh4m",
        "type" => "invoice.payment_succeeded",
        "data" => %{
          "object" => %{
            "object" => "invoice",
            "parent" => %{
              "subscription_details" => %{
                "subscription" => "sub_1U18ivIn2rXVSrRDpMNuy0Gg",
                "metadata" => %{"account_id" => account.id, "tier" => "pro"}
              }
            }
          }
        }
      }

      :ok = Billing.apply_event(real_invoice)

      reloaded = reload(account)
      assert reloaded.plan == :pro
      assert reloaded.stripe_subscription_id == "sub_1U18ivIn2rXVSrRDpMNuy0Gg"
    end

    test "the same event delivered twice grants once" do
      scope = owner_scope()
      account = scope.active_account

      evt =
        event("invoice.payment_succeeded", account.id, %{
          "metadata" => %{"account_id" => account.id, "tier" => "light"}
        })

      assert :ok = Billing.apply_event(evt)
      assert :ok = Billing.apply_event(evt)

      assert reload(account).plan == :light
      assert Repo.aggregate(from(e in CodeMySpec.Billing.StripeEvent, where: e.event_id == ^evt["id"]), :count) == 1
    end

    test "a deleted subscription returns the account to free" do
      scope = owner_scope()
      account = scope.active_account
      {:ok, account} = Accounts.update_account(scope, account, %{plan: :pro})

      :ok = Billing.apply_event(event("customer.subscription.deleted", account.id))

      assert reload(account).plan == :free
    end

    test "a failed renewal keeps the tier while Stripe retries" do
      scope = owner_scope()
      account = scope.active_account
      {:ok, account} = Accounts.update_account(scope, account, %{plan: :pro})

      :ok = Billing.apply_event(event("invoice.payment_failed", account.id))

      assert reload(account).plan == :pro,
             "an expired card must not cost the tier while Stripe is still retrying"
    end

    test "an event for an unknown account changes nothing" do
      assert {:error, :unknown_account} =
               Billing.apply_event(event("invoice.payment_succeeded", Ecto.UUID.generate()))
    end

    test "an event carrying no account reference is refused" do
      evt = %{
        "id" => "evt_none",
        "type" => "invoice.payment_succeeded",
        "data" => %{"object" => %{}}
      }

      assert {:error, :no_account_reference} = Billing.apply_event(evt)
    end
  end
end
