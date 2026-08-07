defmodule CodeMySpecSpex.Story993.Criterion8243Spex do
  @moduledoc """
  Story 993 — Buying a plan puts the account on it.
  Criterion 8243 — Closing the tab after paying still gets the plan.

  Rule: the webhook is the only thing that writes an account's plan.

  This is the criterion the whole fulfilment design exists for. If the page
  granted the tier, a visitor who closed the tab between paying and the page
  reloading would have been charged and left on a free account — and we would
  have no way to know it happened. So the page never grants, and this proves
  the tier arrives with no browser involved at all.

  Surface: the webhook endpoint, posted to exactly as Stripe posts to it,
  signature and all.
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

  spex "The tier arrives without the browser" do
    scenario "Closing the tab after paying still gets the plan" do
      # No given_: a new account already starts free, and the point of this
      # criterion is that nothing else happens first — no LiveView is mounted
      # and no session is held, so the tier cannot arrive from a page.
      when_ "Stripe reports the payment succeeded", context do
        body =
          Jason.encode!(%{
            "id" => "evt_spex_#{System.unique_integer([:positive])}",
            "type" => "invoice.payment_succeeded",
            # Stripe's real invoice shape, captured from a live event: the
            # top-level metadata is empty and the account sits two levels
            # down. This is the criterion that matters most — if the tier
            # only arrives for an invoice we invented, a paying customer who
            # closed the tab gets nothing.
            "data" => %{
              "object" => %{
                "object" => "invoice",
                "metadata" => %{},
                "parent" => %{
                  "type" => "subscription_details",
                  "subscription_details" => %{
                    "subscription" => "sub_spex_closed_tab",
                    "metadata" => %{"account_id" => context.account.id, "tier" => "pro"}
                  }
                }
              }
            }
          })

        conn =
          build_conn()
          |> put_req_header("content-type", "application/json")
          |> put_req_header("stripe-signature", signature(body))
          |> post("/webhooks/stripe", body)

        {:ok, Map.put(context, :status, conn.status)}
      end

      then_ "Stripe is told we took it", context do
        assert context.status == 200

        {:ok, context}
      end

      then_ "the account is on the tier that was paid for", context do
        # Read off the pricing page, which is the first page a returning
        # visitor would see. Asking the database here would prove the row
        # changed; asking the page proves the account is *on* the tier from
        # anywhere it matters — and the browser is only involved now, after
        # the fact, which is the whole point of the criterion.
        assert plan_on_page(context.conn) == "pro",
               "the tier must arrive from the webhook alone, with no page involved"

        {:ok, context}
      end
    end
  end

  # Signs the body the way Stripe does, so the endpoint is exercised through
  # its real gate rather than around it.
  defp signature(body) do
    ts = System.system_time(:second)
    mac = :crypto.mac(:hmac, :sha256, @secret, "#{ts}.#{body}") |> Base.encode16(case: :lower)
    "t=#{ts},v1=#{mac}"
  end
end
