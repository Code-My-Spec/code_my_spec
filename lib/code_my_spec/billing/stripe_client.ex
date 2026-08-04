defmodule CodeMySpec.Billing.StripeClient do
  @moduledoc """
  Thin hand-written Stripe REST client over Req — no SDK.

  Form-encoded because Stripe does not accept JSON bodies, a pinned
  `Stripe-Version` so a Stripe-side release cannot change our behaviour
  silently, and an `Idempotency-Key` on every POST so a retried request never
  charges twice.

  A `:plug` is injectable in test so nothing here reaches the network in CI.
  Returns `{:ok, body}` for 2xx and `{:error, %{status:, body:}}` otherwise —
  Stripe's own error body is preserved rather than collapsed, because its
  `decline_code` is the only thing that tells a user why a card failed.

  Pattern taken from ../get_ai_traffic (story 757); see
  `.code_my_spec/knowledge/stripe/`.
  """

  @base_url "https://api.stripe.com"
  @stripe_version "2026-05-27.dahlia"

  @doc "Creates a Stripe Customer for an account. Reused forever after."
  def create_customer(params), do: post("/v1/customers", params)

  @doc """
  Creates the subscription behind the embedded Payment Element.

  `payment_behavior=default_incomplete` leaves it unpaid until the browser
  confirms, and `expand[0]=latest_invoice.confirmation_secret` is what returns
  the client secret to confirm with — without the expand there is nothing for
  the Payment Element to act on.
  """
  def create_subscription(params), do: post("/v1/subscriptions", params)

  @doc "Retrieves a subscription — e.g. to read its status after a webhook."
  def get_subscription(id), do: get("/v1/subscriptions/#{id}")

  @doc "Cancels at period end. The account keeps the tier it paid for until then."
  def cancel_subscription_at_period_end(id),
    do: post("/v1/subscriptions/#{id}", %{"cancel_at_period_end" => "true"})

  # --- HTTP ---

  defp post(path, form) do
    with {:ok, key} <- fetch_secret_key() do
      key
      |> req()
      |> Req.post(url: path, form: form, headers: [{"idempotency-key", Ecto.UUID.generate()}])
      |> handle()
    end
  end

  defp get(path) do
    with {:ok, key} <- fetch_secret_key() do
      key |> req() |> Req.get(url: path) |> handle()
    end
  end

  defp req(key) do
    opts = [
      base_url: @base_url,
      auth: {:bearer, key},
      headers: [{"stripe-version", @stripe_version}],
      decode_json: [keys: :strings]
    ]

    case config()[:plug] do
      nil -> Req.new(opts)
      plug -> Req.new(Keyword.put(opts, :plug, plug))
    end
  end

  # Req's `auth: {:bearer, _}` step has no clause for a missing key, so an
  # unconfigured Stripe would crash the caller inside Req rather than surface
  # as an error the page can show.
  defp fetch_secret_key do
    case config()[:secret_key] do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, %{status: nil, body: :stripe_not_configured}}
    end
  end

  defp handle({:ok, %Req.Response{status: status, body: body}}) when status in 200..299,
    do: {:ok, body}

  defp handle({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, %{status: status, body: body}}

  defp handle({:error, reason}), do: {:error, %{status: nil, body: reason}}

  defp config, do: Application.get_env(:code_my_spec, __MODULE__, [])
end
