defmodule CodeMySpecSpex.Story993.Criterion794Spex do
  @moduledoc """
  Story 993 — Buying a plan puts the account on it.
  Criterion 794 — A user picks a tier and pays for it in place.

  The pricing page embeds CheckoutLive. Stripe's Payment Element owns the card
  fields; the app gives it a mount point and a client secret. A successful card
  payment should leave the buyer on the pricing page.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  setup do
    Application.put_env(:code_my_spec, CodeMySpec.Billing.StripeClient,
      secret_key: "sk_test_pricing",
      plug: {Req.Test, CodeMySpec.Billing.StripeClient}
    )

    Application.put_env(:code_my_spec, CodeMySpec.Billing,
      light_price_id: "price_light_pricing",
      pro_price_id: "price_pro_pricing",
      publishable_key: "pk_test_pricing"
    )

    Req.Test.stub(CodeMySpec.Billing.StripeClient, &stripe_response/1)

    on_exit(fn ->
      Application.delete_env(:code_my_spec, CodeMySpec.Billing.StripeClient)
      Application.delete_env(:code_my_spec, CodeMySpec.Billing)
    end)

    :ok
  end

  spex "A buyer pays for the light harness tier on the pricing page", criterion: 794 do
    scenario "card payment stays in place and card fields belong to Stripe" do
      given_ "a signed-in user on a free account looking at pricing", context do
        # given: already true — `setup :register_log_in_setup_account` creates
        # the signed-in free account; this block opens its pricing page.
        pricing_html = context.conn |> get("/pricing") |> html_response(200)
        {:ok, checkout, _html} = live_isolated(context.conn, CodeMySpecWeb.CheckoutLive)

        {:ok, Map.merge(context, %{pricing_html: pricing_html, checkout: checkout})}
      end

      when_ "they choose light harness and complete the card payment", context do
        context.checkout
        |> element("button[phx-value-tier='light']")
        |> render_click()

        payment_html = render(context.checkout)
        confirmation = render_hook(context.checkout, "payment_confirmed", %{})

        {:ok, Map.merge(context, %{payment_html: payment_html, confirmation: confirmation})}
      end

      then_ "Stripe owns the card fields and the payment finishes on the pricing page", context do
        assert context.pricing_html =~ "Light harness"
        assert context.payment_html =~ ~s(phx-hook="StripePaymentElement")
        assert context.payment_html =~ ~s(id="payment-element")
        refute context.payment_html =~ ~r/<input[^>]+(?:card|cvc|expiry)/i

        refute match?({:error, {:redirect, _}}, context.confirmation),
               "a successful card payment navigated away from pricing"

        assert render(context.checkout) =~ "Light harness"
        {:ok, context}
      end
    end
  end

  defp stripe_response(%{request_path: "/v1/customers"} = conn) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "cus_pricing"}))
  end

  defp stripe_response(%{request_path: "/v1/subscriptions"} = conn) do
    body = %{
      "id" => "sub_pricing",
      "latest_invoice" => %{
        "confirmation_secret" => %{"client_secret" => "pi_pricing_secret"}
      }
    }

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end
end
