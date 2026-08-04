defmodule CodeMySpecSpex.Story993.Criterion8247Spex do
  @moduledoc """
  Story 993 — Buying a plan puts the account on it.
  Criterion 8247 — Cancelling keeps the tier until the paid period ends.

  Rule: a subscription that ends returns the account to free.

  They paid for the month, so they get the month. The distinction is not
  cosmetic: Stripe sends a different event for "will cancel at period end"
  than for "has ended", and acting on the wrong one takes away time someone
  already bought.

  Surface: the webhook endpoint, given each event in turn.
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

  spex "Cancelling does not take back time already paid for" do
    scenario "Cancelling keeps the tier until the paid period ends" do
      given_ "an account on a paid tier partway through a paid month", context do
        # Posted inline rather than through the helper, so this block visibly
        # drives the endpoint it depends on instead of asserting a state it
        # did nothing to create.
        body = event_body(context.account.id, "invoice.payment_succeeded", %{"tier" => "pro"})
        post(signed(body), "/webhooks/stripe", body)

        assert plan(context.account.id) == :pro

        {:ok, context}
      end

      when_ "the user cancels, and Stripe says it will end at period end", context do
        post_event(context.account.id, "customer.subscription.updated", %{
          "cancel_at_period_end" => true
        })

        {:ok, context}
      end

      then_ "they still have the tier they paid for", context do
        assert plan(context.account.id) == :pro,
               "cancelling must not take back the rest of a month already bought"

        {:ok, context}
      end

      then_ "only when the period actually ends do they return to free", context do
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
    body = event_body(account_id, type, attrs)
    post(signed(body), "/webhooks/stripe", body)
  end

  defp event_body(account_id, type, attrs) do
    {tier, object} = Map.pop(attrs, "tier")
    metadata = %{"account_id" => account_id} |> maybe_put("tier", tier)

    Jason.encode!(%{
      "id" => "evt_#{System.unique_integer([:positive])}",
      "type" => type,
      "data" => %{"object" => Map.put(object, "metadata", metadata)}
    })
  end

  defp signed(body) do
    ts = System.system_time(:second)
    mac = :crypto.mac(:hmac, :sha256, @secret, "#{ts}.#{body}") |> Base.encode16(case: :lower)

    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("stripe-signature", "t=#{ts},v1=#{mac}")
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
