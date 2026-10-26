defmodule CodeMySpecSpex.Story993.Criterion796Spex do
  @moduledoc """
  Story 993 — Buying a plan puts the account on it.
  Criterion 796 — The page saying it worked does not by itself grant a plan.

  The browser's payment confirmation is a message to the user, not evidence
  that Stripe settled the invoice. The account's tier follows the webhook.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint
  @secret "whsec_unconfirmed_payment"

  setup :register_log_in_setup_account

  setup do
    Application.put_env(:code_my_spec, CodeMySpec.Billing, webhook_secret: @secret)
    on_exit(fn -> Application.delete_env(:code_my_spec, CodeMySpec.Billing) end)
    :ok
  end

  spex "A page success message cannot grant an unconfirmed plan", criterion: 796 do
    scenario "Stripe reports a failed payment after the browser reports success" do
      given_ "a free account whose payment has not been confirmed by Stripe", context do
        {:ok, checkout, _html} = live_isolated(context.conn, CodeMySpecWeb.CheckoutLive)
        {:ok, Map.put(context, :checkout, checkout)}
      end

      when_ "the page reports success but Stripe reports the payment failed", context do
        page_result = render_hook(context.checkout, "payment_confirmed", %{})
        body = failed_invoice(context.account.id)

        webhook =
          build_conn()
          |> put_req_header("content-type", "application/json")
          |> put_req_header("stripe-signature", signature(body))
          |> post("/webhooks/stripe", body)

        {:ok, Map.merge(context, %{page_result: page_result, webhook_status: webhook.status})}
      end

      then_ "the page alone has not granted a paid tier", context do
        assert match?({:error, {:redirect, _}}, context.page_result)
        assert context.webhook_status == 200
        assert plan_on_page(context.conn) == nil
        {:ok, context}
      end

      then_ "the pricing page corrects any optimistic paid state", context do
        html = context.conn |> get("/pricing") |> html_response(200)

        assert html =~ "Choose Light harness"
        refute html =~ ~s(data-test="current-plan" data-plan="light")
        {:ok, context}
      end
    end
  end

  defp failed_invoice(account_id) do
    Jason.encode!(%{
      "id" => "evt_failed_#{System.unique_integer([:positive])}",
      "type" => "invoice.payment_failed",
      "data" => %{
        "object" => %{
          "object" => "invoice",
          "metadata" => %{},
          "parent" => %{
            "type" => "subscription_details",
            "subscription_details" => %{
              "subscription" => "sub_unconfirmed_payment",
              "metadata" => %{"account_id" => account_id, "tier" => "light"}
            }
          }
        }
      }
    })
  end

  defp signature(body) do
    ts = System.system_time(:second)
    mac = :crypto.mac(:hmac, :sha256, @secret, "#{ts}.#{body}") |> Base.encode16(case: :lower)
    "t=#{ts},v1=#{mac}"
  end
end
