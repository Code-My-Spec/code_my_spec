defmodule CodeMySpecWeb.StripeWebhookController do
  @moduledoc """
  The only thing that grants or removes a paid tier.

  Unauthenticated by session and exempt from CSRF, because Stripe is not a
  browser — the request authenticates itself with an HMAC over the exact bytes
  Stripe signed. `CodeMySpecWeb.CacheBodyReader` already stashes those bytes
  for anything under `/webhooks/`, which is why this route must live there:
  re-encoding the parsed params would change them and no signature would ever
  verify.
  """

  use CodeMySpecWeb, :controller

  alias CodeMySpec.Billing

  require Logger

  # Stripe's own tolerance. Bounds how long a captured request stays replayable
  # if it ever leaks.
  @replay_window_seconds 300

  def create(conn, _params) do
    signature = conn |> get_req_header("stripe-signature") |> List.first()

    case verify(raw_body(conn), signature, webhook_secret()) do
      :ok ->
        apply_event(conn)

      {:error, reason} ->
        # 400, not 500: Stripe retries a 5xx, and there is no point retrying a
        # request that will never verify.
        Logger.warning("[Stripe] webhook rejected: #{inspect(reason)}")
        send_resp(conn, 400, "")
    end
  end

  # A signed event we could not apply must NOT answer 200. Stripe stops
  # retrying on a 2xx, so answering "thanks" to a failure is how a charged card
  # ends up on a free account with nothing to notice it — which is exactly what
  # happened. 5xx puts the event back in Stripe's retry schedule, so the same
  # payment lands by itself once the cause is fixed.
  defp apply_event(conn) do
    case Billing.apply_event(conn.body_params) do
      :ok ->
        send_resp(conn, 200, "")

      {:error, reason} ->
        Logger.error("[Stripe] event accepted but not applied: #{inspect(reason)}")
        send_resp(conn, 500, "")
    end
  end

  @doc false
  # Stripe sends `t=<unix>,v1=<hex>`: HMAC-SHA256 over "<t>.<raw body>",
  # inside the replay window, compared in constant time.
  def verify(_raw_body, nil, _secret), do: {:error, :missing_signature}
  def verify("", _signature, _secret), do: {:error, :no_raw_body}

  def verify(raw_body, signature, secret) do
    parts =
      for kv <- String.split(signature, ","),
          [k, v] <- [String.split(kv, "=", parts: 2)],
          into: %{},
          do: {k, v}

    with %{"t" => ts, "v1" => v1} <- parts,
         {t, ""} <- Integer.parse(ts),
         true <- abs(System.system_time(:second) - t) <= @replay_window_seconds,
         expected <-
           :crypto.mac(:hmac, :sha256, secret, "#{ts}.#{raw_body}") |> Base.encode16(case: :lower),
         true <- Plug.Crypto.secure_compare(expected, v1) do
      :ok
    else
      _ -> {:error, :invalid_signature}
    end
  end

  # The reader prepends chunks, so they come back reversed.
  defp raw_body(conn) do
    case conn.assigns[:raw_body] do
      nil -> ""
      chunks -> chunks |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  defp webhook_secret do
    Application.get_env(:code_my_spec, CodeMySpec.Billing, [])[:webhook_secret] || ""
  end
end
