defmodule CodeMySpecSpex.Story993.UnappliedEventSpex do
  @moduledoc """
  Story 993 — regression, from the same QA session as the invoice-shape bug.

  When the metadata bug swallowed a real payment, the endpoint answered 200.
  Stripe takes 2xx as "handled" and stops retrying, so the charge was lost
  quietly and permanently — the fix could not recover it afterwards because
  there was nothing left to redeliver.

  A signed event we failed to apply has to answer 5xx. Then it stays in
  Stripe's retry schedule for days, and the same payment lands by itself once
  whatever broke is fixed. That is the difference between a bug that costs an
  afternoon and a bug that costs a customer's money.
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

  # The unapplied event logs :error on purpose — that log is how anyone finds
  # out a payment did not land, so it is the behaviour under test, not noise.
  spex "An event we could not apply stays retryable", fail_on_error_logs: false do
    scenario "A signed event naming no account is not answered with success" do
      when_ "Stripe posts a properly signed event we cannot attribute", context do
        body =
          Jason.encode!(%{
            "id" => "evt_unattributable_#{System.unique_integer([:positive])}",
            "type" => "invoice.payment_succeeded",
            "data" => %{"object" => %{"object" => "invoice", "metadata" => %{}}}
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

      then_ "Stripe is told to try again rather than that we handled it", context do
        assert context.status >= 500,
               "a 2xx here is how a charged card ends up on a free account with " <>
                 "nothing left to redeliver"

        {:ok, context}
      end
    end
  end
end
