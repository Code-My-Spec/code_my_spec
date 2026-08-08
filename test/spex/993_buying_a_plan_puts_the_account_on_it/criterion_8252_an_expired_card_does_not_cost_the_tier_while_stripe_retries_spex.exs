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
        # Posted inline rather than through the helper, so this block visibly
        # drives the endpoint it depends on.
        body = event_body(context.account.id, "invoice.payment_succeeded", %{"tier" => "light"})
        post(signed(body), "/webhooks/stripe", body)

        assert plan(context.conn) == :light

        {:ok, context}
      end

      when_ "the renewal payment fails and Stripe starts retrying", context do
        conn = post_event(context.account.id, "invoice.payment_failed", %{})

        {:ok, Map.put(context, :status, conn.status)}
      end

      then_ "the account keeps its tier", context do
        assert plan(context.conn) == :light,
               "an expired card must not cost the tier while it can still be fixed"

        assert context.status == 200

        {:ok, context}
      end

      then_ "only when Stripe gives up does the account return to free", context do
        post_event(context.account.id, "customer.subscription.deleted", %{})

        assert plan(context.conn) == :free

        {:ok, context}
      end
    end
  end

  # Read off the pricing page rather than the database: a `then_` observes
  # through the public interface, and reaching into `CodeMySpec.Accounts` also
  # breaks the CodeMySpecSpex boundary. A free account badges no tier, since
  # free is not one of the purchasable ones, so an absent badge is `:free`.
  defp plan(conn) do
    case plan_on_page(conn) do
      nil -> :free
      tier -> String.to_existing_atom(tier)
    end
  end

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
      "data" => %{"object" => with_metadata(object, type, metadata)}
    })
  end

  # Checked against Stripe rather than assumed: a real subscription-backed
  # invoice.payment_failed carries an EMPTY top-level metadata and puts the
  # account under parent.subscription_details. Building every event with
  # metadata on top let this spec pass on a shape Stripe never sends.
  defp with_metadata(object, "invoice." <> _, metadata) do
    object
    |> Map.put("object", "invoice")
    |> Map.put("metadata", %{})
    |> Map.put("parent", %{
      "type" => "subscription_details",
      "subscription_details" => %{
        "subscription" => "sub_spex_#{System.unique_integer([:positive])}",
        "metadata" => metadata
      }
    })
  end

  # A subscription event is the subscription, and does carry its own metadata.
  defp with_metadata(object, _type, metadata), do: Map.put(object, "metadata", metadata)

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
