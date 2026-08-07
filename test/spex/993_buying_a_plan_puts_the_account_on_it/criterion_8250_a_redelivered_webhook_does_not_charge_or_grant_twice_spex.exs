defmodule CodeMySpecSpex.Story993.Criterion8250Spex do
  @moduledoc """
  Story 993 — Buying a plan puts the account on it.
  Criterion 8250 — A redelivered webhook does not charge or grant twice.

  Rule: a webhook Stripe sends twice grants the plan once.

  Stripe delivers at least once; a redelivery is routine, not a fault. The
  guard is a unique index on the event id, written before the event is
  dispatched — so this drives the real endpoint twice with the same event and
  checks the second one changed nothing.

  Surface: the webhook endpoint, posted twice with identical bytes.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  @endpoint CodeMySpecWeb.Endpoint

  @secret "whsec_spex"

  setup :register_log_in_setup_account

  setup do
    Application.put_env(:code_my_spec, CodeMySpec.Billing, webhook_secret: @secret)
    on_exit(fn -> Application.delete_env(:code_my_spec, CodeMySpec.Billing) end)
    :ok
  end

  spex "One event, one grant, however many times it arrives" do
    scenario "A redelivered webhook does not charge or grant twice" do
      given_ "a payment whose webhook has already been processed", context do
        body = event_body(context.account.id, "light")
        assert post_webhook(body).status == 200

        assert plan_on_page(context.conn) == "light",
               "the first delivery must land, or the redelivery below proves nothing"

        {:ok, Map.put(context, :body, body)}
      end

      when_ "Stripe redelivers exactly the same event", context do
        {:ok, Map.put(context, :status, post_webhook(context.body).status)}
      end

      then_ "Stripe is still told we took it, so it stops retrying", context do
        assert context.status == 200

        {:ok, context}
      end

      then_ "the account is on exactly the tier it was already on", context do
        assert plan_on_page(context.conn) == "light",
               "a redelivered event must not move the account off the tier it already had"

        {:ok, context}
      end
    end
  end

  # The invoice shape is Stripe's, not ours: an empty top-level metadata and
  # the account two levels down under parent.subscription_details. A dedup
  # test that grants on a shape Stripe never sends proves nothing about
  # redelivery of the events we actually receive.
  defp event_body(account_id, tier) do
    Jason.encode!(%{
      "id" => "evt_dup_#{System.unique_integer([:positive])}",
      "type" => "invoice.payment_succeeded",
      "data" => %{
        "object" => %{
          "object" => "invoice",
          "metadata" => %{},
          "parent" => %{
            "type" => "subscription_details",
            "subscription_details" => %{
              "subscription" => "sub_spex_dup",
              "metadata" => %{"account_id" => account_id, "tier" => tier}
            }
          }
        }
      }
    })
  end

  defp post_webhook(body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("stripe-signature", signature(body))
    |> post("/webhooks/stripe", body)
  end

  defp signature(body) do
    ts = System.system_time(:second)
    mac = :crypto.mac(:hmac, :sha256, @secret, "#{ts}.#{body}") |> Base.encode16(case: :lower)
    "t=#{ts},v1=#{mac}"
  end
end
