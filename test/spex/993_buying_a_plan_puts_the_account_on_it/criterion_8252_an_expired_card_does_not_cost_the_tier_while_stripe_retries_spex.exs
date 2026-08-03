defmodule CodeMySpecSpex.Story993.Criterion8252Spex do
  @moduledoc """
  Story 993 — Buying a plan puts the account on it.
  Criterion 8252 — An expired card does not cost the tier while Stripe retries.

  Rule: a tier survives a failed renewal for as long as Stripe is still
  retrying it.

  Most failed renewals are a card that expired and gets replaced. Stripe
  retries for days before giving up, and cutting someone off at the first
  failure loses a paying customer over something recoverable — so the tier
  stays until Stripe itself is done trying.

  Surface: the webhook endpoint, given a failure and then the terminal event.
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

  spex "A recoverable payment failure does not cost the tier" do
    scenario "An expired card does not cost the tier while Stripe retries" do
      given_ "an account on a paid tier", context do
        post_event(context.account.id, "invoice.payment_succeeded", %{"tier" => "light"})
        assert plan(context.account.id) == :light

        {:ok, context}
      end

      when_ "the renewal payment fails and Stripe starts retrying", context do
        conn = post_event(context.account.id, "invoice.payment_failed", %{})

        {:ok, Map.put(context, :status, conn.status)}
      end

      then_ "the account keeps its tier", context do
        assert plan(context.account.id) == :light,
               "an expired card must not cost the tier while it can still be fixed"

        assert context.status == 200

        {:ok, context}
      end

      then_ "only when Stripe gives up does the account return to free", context do
        post_event(context.account.id, "customer.subscription.deleted", %{})

        assert plan(context.account.id) == :free

        {:ok, context}
      end
    end
  end

  defp plan(account_id), do: CodeMySpec.Accounts.get_account_by_id(account_id).plan

  # The tier belongs inside metadata, where the handler reads it — merging it
  # at the object level looked right and silently sent no tier at all.
  defp post_event(account_id, type, attrs) do
    {tier, object} = Map.pop(attrs, "tier")
    metadata = %{"account_id" => account_id} |> maybe_put("tier", tier)

    body =
      Jason.encode!(%{
        "id" => "evt_#{System.unique_integer([:positive])}",
        "type" => type,
        "data" => %{"object" => Map.put(object, "metadata", metadata)}
      })

    ts = System.system_time(:second)
    mac = :crypto.mac(:hmac, :sha256, @secret, "#{ts}.#{body}") |> Base.encode16(case: :lower)

    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("stripe-signature", "t=#{ts},v1=#{mac}")
    |> post("/webhooks/stripe", body)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
