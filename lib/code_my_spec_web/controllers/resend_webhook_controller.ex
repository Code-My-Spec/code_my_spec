defmodule CodeMySpecWeb.ResendWebhookController do
  @moduledoc """
  Inbound mail webhook for the Resend Receiving API.

  Resend POSTs an `email.received` event here; we verify its Svix signature,
  resolve the owning project by the To-address domain, and route the message
  into a mailbox (catch-all fallback) via `CodeMySpec.Mail.route_inbound/2`.
  We always answer 200 on accepted events so the provider doesn't retry on
  messages we have nowhere to put.

  Signatures are verified against `RESEND_WEBHOOK_SECRET` (Svix `whsec_…`). When
  no secret is configured (dev without inbound, tests) verification is skipped
  so the endpoint stays usable; once a secret is set, a bad/missing signature
  is rejected with 400.
  """

  use CodeMySpecWeb, :controller

  require Logger

  alias CodeMySpec.Mail

  def inbound(conn, %{"type" => "email.received", "data" => data} = _params) when is_map(data) do
    case verify_signature(conn) do
      :ok ->
        route(data)
        send_resp(conn, 200, "ok")

      {:error, :invalid_signature} ->
        Logger.warning("[ResendWebhook] rejected event with invalid signature")
        send_resp(conn, 400, "bad signature")
    end
  end

  def inbound(conn, _params) do
    case verify_signature(conn) do
      :ok -> send_resp(conn, 200, "ok")
      {:error, :invalid_signature} -> send_resp(conn, 400, "bad signature")
    end
  end

  defp route(data) do
    to = data |> Map.get("to") |> List.wrap() |> List.first()

    with domain when is_binary(domain) <- address_domain(to),
         project when not is_nil(project) <- Mail.get_project_by_domain(domain) do
      Mail.route_inbound(project, %{
        from: Map.get(data, "from"),
        to: Map.get(data, "to"),
        subject: Map.get(data, "subject"),
        text: Map.get(data, "text"),
        html: Map.get(data, "html"),
        message_id: Map.get(data, "message_id"),
        in_reply_to: Map.get(data, "in_reply_to")
      })
    end
  end

  # --- Signature verification (Svix) ---

  defp verify_signature(conn) do
    case webhook_secret() do
      secret when is_binary(secret) and secret != "" -> do_verify(conn, secret)
      _ -> :ok
    end
  end

  defp do_verify(conn, secret) do
    with [svix_id] <- get_req_header(conn, "svix-id"),
         [svix_timestamp] <- get_req_header(conn, "svix-timestamp"),
         [svix_signature] <- get_req_header(conn, "svix-signature"),
         {:ok, key} <- decode_secret(secret) do
      signed = "#{svix_id}.#{svix_timestamp}.#{raw_body(conn)}"
      expected = :crypto.mac(:hmac, :sha256, key, signed) |> Base.encode64()

      provided =
        svix_signature
        |> String.split(" ", trim: true)
        |> Enum.map(fn
          "v1," <> sig -> sig
          sig -> sig
        end)

      if Enum.any?(provided, &Plug.Crypto.secure_compare(&1, expected)),
        do: :ok,
        else: {:error, :invalid_signature}
    else
      _ -> {:error, :invalid_signature}
    end
  end

  defp decode_secret(secret) do
    case secret |> String.replace_prefix("whsec_", "") |> Base.decode64() do
      {:ok, key} -> {:ok, key}
      :error -> :error
    end
  end

  defp raw_body(conn) do
    case conn.assigns[:raw_body] do
      nil -> ""
      chunks -> chunks |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  defp webhook_secret, do: Application.get_env(:code_my_spec, :resend_webhook_secret, "")

  defp address_domain(address) when is_binary(address) do
    case String.split(address, "@", parts: 2) do
      [_local, domain] when domain != "" -> domain
      _ -> nil
    end
  end

  defp address_domain(_), do: nil
end
