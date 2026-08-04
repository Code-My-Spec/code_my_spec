defmodule CodeMySpecSpex.Story993.Criterion8251Spex do
  @moduledoc """
  Story 993 — Buying a plan puts the account on it.
  Criterion 8251 — A webhook that is not really from Stripe is refused.

  Rule: a webhook Stripe sends twice grants the plan once.

  The endpoint has no session and no CSRF token — it is a public URL whose
  only gate is the signature. So the obvious attack is to post the upgrade
  yourself, and this proves that a body which is not signed by Stripe grants
  nothing.

  Surface: the webhook endpoint, posted to without a valid signature.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  setup do
    Application.put_env(:code_my_spec, CodeMySpec.Billing, webhook_secret: "whsec_spex")
    on_exit(fn -> Application.delete_env(:code_my_spec, CodeMySpec.Billing) end)
    :ok
  end

  spex "Only Stripe can grant a tier" do
    scenario "A webhook that is not really from Stripe is refused" do
      # No given_: a new account already starts free, which is the whole
      # precondition — the scenario is about what a forged request cannot do.
      when_ "someone posts an upgrade with a signature that does not verify", context do
        body =
          Jason.encode!(%{
            "id" => "evt_forged",
            "type" => "invoice.payment_succeeded",
            "data" => %{
              "object" => %{"metadata" => %{"account_id" => context.account.id, "tier" => "pro"}}
            }
          })

        conn =
          build_conn()
          |> put_req_header("content-type", "application/json")
          |> put_req_header("stripe-signature", "t=#{System.system_time(:second)},v1=deadbeef")
          |> post("/webhooks/stripe", body)

        {:ok, Map.put(context, :status, conn.status)}
      end

      then_ "the request is rejected rather than processed on trust", context do
        assert context.status == 400,
               "a 5xx would make Stripe retry a request that can never verify"

        {:ok, context}
      end

      then_ "no account is put on a paid tier", context do
        # No tier is badged as theirs. `free` is not one of the purchasable
        # tiers, so "still free" is observable as the page offering both tiers
        # to buy rather than marking either as already owned.
        refute plan_on_page(context.conn),
               "a forged webhook granted a paid tier"

        {:ok, context}
      end
    end
  end
end
