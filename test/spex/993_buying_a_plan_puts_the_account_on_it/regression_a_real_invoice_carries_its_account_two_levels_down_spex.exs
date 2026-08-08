defmodule CodeMySpecSpex.Story993.RealInvoiceShapeSpex do
  @moduledoc """
  Story 993 — regression, found in QA against real Stripe.

  A live `invoice.payment_succeeded` arrived, was accepted, deduped — and
  granted nothing. The account stayed free while the card had been charged.

  The reason is that an invoice does not carry the subscription's metadata
  where the hand-written test events put it. Its own `metadata` is `{}`, and
  the subscription's is mirrored at `parent.subscription_details.metadata`.
  Every unit test passed because every unit test built the event itself and
  put the id where the code already looked.

  So this spex uses the payload shape Stripe actually sends, and nothing else.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @secret "whsec_spex"

  setup :register_log_in_setup_account

  setup do
    Application.put_env(:code_my_spec, CodeMySpec.Billing, webhook_secret: @secret)
    on_exit(fn -> Application.delete_env(:code_my_spec, CodeMySpec.Billing) end)
    :ok
  end

  spex "A real invoice's account id is found where Stripe puts it" do
    scenario "An invoice carrying its account two levels down still grants the tier" do
      when_ "Stripe posts an invoice shaped the way it really shapes them", context do
        # Verbatim from evt_1U0X1SIn2rXVSrRD06SlDsfQ: empty top-level metadata,
        # the real ids under parent.subscription_details.
        body =
          Jason.encode!(%{
            "id" => "evt_real_#{System.unique_integer([:positive])}",
            "type" => "invoice.payment_succeeded",
            "data" => %{
              "object" => %{
                "object" => "invoice",
                "metadata" => %{},
                "parent" => %{
                  "subscription_details" => %{
                    "metadata" => %{"account_id" => context.account.id, "tier" => "pro"}
                  }
                }
              }
            }
          })

        ts = System.system_time(:second)
        mac = :crypto.mac(:hmac, :sha256, @secret, "#{ts}.#{body}") |> Base.encode16(case: :lower)

        conn =
          build_conn()
          |> put_req_header("content-type", "application/json")
          |> put_req_header("stripe-signature", "t=#{ts},v1=#{mac}")
          |> post("/webhooks/stripe", body)

        {:ok, Map.put(context, :status, conn.status)}
      end

      then_ "the account is on the tier that was paid for", context do
        assert context.status == 200

        assert plan_on_page(context.conn) == "pro",
               "a real invoice must grant the tier, not just be accepted and deduped"

        {:ok, context}
      end
    end
  end
end
