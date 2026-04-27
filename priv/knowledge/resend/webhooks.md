# Resend Webhooks

Resend delivers event notifications via HTTPS POST to an endpoint you register. All webhooks are signed using Svix.

## Available events

### Email events

| Event | Triggered when |
|---|---|
| `email.sent` | API request succeeded, message queued |
| `email.delivered` | Recipient's mail server accepted the message |
| `email.delivery_delayed` | Temporary failure (soft bounce, greylisting) |
| `email.bounced` | Recipient's mail server permanently rejected the message |
| `email.complained` | Recipient marked the message as spam |
| `email.opened` | Recipient opened the email (requires open tracking) |
| `email.clicked` | Recipient clicked a tracked link |
| `email.scheduled` | Email was scheduled for future delivery |
| `email.failed` | Send failed due to a permanent error |
| `email.suppressed` | Resend suppressed the email (bounce/complaint list) |
| `email.received` | Inbound email received (requires inbound setup) |

### Domain events

`domain.created`, `domain.updated`, `domain.deleted`

### Contact events

`contact.created`, `contact.updated`, `contact.deleted`

## Webhook payload shape

```json
{
  "type": "email.delivered",
  "created_at": "2026-04-26T14:32:00.000Z",
  "data": {
    "email_id": "49a3999c-0ce1-4ea6-ab68-afcd6dc2e794",
    "from": "contact@codemyspec.com",
    "to": ["user@example.com"],
    "subject": "Your receipt",
    "tags": [{"name": "type", "value": "receipt"}]
  }
}
```

Delivery is at-least-once. Use the `svix-id` header as a deduplication key — store it and discard duplicates.

Events are not guaranteed to arrive in order. Use `created_at` for sequencing.

Retry schedule: 5 s, 5 min, 30 min, 2 h, 5 h, 10 h.

## Registering an endpoint

### CLI

```bash
resend webhooks create \
  --endpoint https://codemyspec.com/webhooks/resend \
  --events email.delivered,email.bounced,email.complained

# Local dev tunnel
resend webhooks listen \
  --url http://localhost:4000/webhooks/resend \
  --events email.delivered,email.bounced
```

### API

```bash
curl -sS -X POST https://api.resend.com/webhooks \
  -H "Authorization: Bearer $RESEND_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "endpoint_url": "https://codemyspec.com/webhooks/resend",
    "events": ["email.delivered", "email.bounced", "email.complained"]
  }'
```

The response includes a `signing_secret` — store it as `RESEND_WEBHOOK_SECRET`. Retrieve it later with `GET /webhooks/{id}`.

## Signature verification

Every request includes three Svix headers:

| Header | Content |
|---|---|
| `svix-id` | Unique message ID (dedup key) |
| `svix-timestamp` | Unix seconds when the message was sent |
| `svix-signature` | Space-delimited list of `v1,<base64-signature>` tokens |

### How the signature is computed

Resend signs `"{svix-id}.{svix-timestamp}.{raw-body}"` with HMAC-SHA256. The signing key is the base64 portion of the `whsec_` secret (strip the `whsec_` prefix, Base64-decode the remainder).

### Raw body requirement

Phoenix parses the request body before your controller runs. Verification requires the original raw bytes. Add a custom body reader to your endpoint:

```elixir
# lib/code_my_spec_web/endpoint.ex
plug Plug.Parsers,
  parsers: [:urlencoded, :multipart, :json],
  pass: ["*/*"],
  body_reader: {CodeMySpecWeb.CacheBodyReader, :read_body, []},
  json_decoder: Phoenix.json_library()
```

```elixir
# lib/code_my_spec_web/cache_body_reader.ex
defmodule CodeMySpecWeb.CacheBodyReader do
  def read_body(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, opts)
    conn = update_in(conn.assigns[:raw_body], &[body | (&1 || [])])
    {:ok, body, conn}
  end
end
```

### Verification in the controller

```elixir
defmodule CodeMySpecWeb.ResendWebhookController do
  use CodeMySpecWeb, :controller
  require Logger

  @secret System.get_env("RESEND_WEBHOOK_SECRET") || ""

  def handle(conn, _params) do
    raw_body = conn.assigns[:raw_body] |> Enum.reverse() |> IO.iodata_to_binary()

    with :ok <- verify_signature(conn, raw_body),
         {:ok, event} <- Jason.decode(raw_body) do
      process_event(event)
      send_resp(conn, 200, "ok")
    else
      {:error, :invalid_signature} ->
        Logger.warning("[Webhook] Invalid Resend signature")
        send_resp(conn, 400, "bad signature")

      {:error, reason} ->
        Logger.error("[Webhook] Parse error: #{inspect(reason)}")
        send_resp(conn, 422, "unprocessable")
    end
  end

  defp verify_signature(conn, raw_body) do
    svix_id        = get_req_header(conn, "svix-id") |> List.first()
    svix_timestamp = get_req_header(conn, "svix-timestamp") |> List.first()
    svix_signature = get_req_header(conn, "svix-signature") |> List.first()

    if is_nil(svix_id) or is_nil(svix_timestamp) or is_nil(svix_signature) do
      {:error, :invalid_signature}
    else
      signed_content = "#{svix_id}.#{svix_timestamp}.#{raw_body}"

      # whsec_ prefix stripped, then base64-decoded
      secret_bytes =
        @secret
        |> String.replace_prefix("whsec_", "")
        |> Base.decode64!()

      expected =
        :crypto.mac(:hmac, :sha256, secret_bytes, signed_content)
        |> Base.encode64()

      incoming_signatures =
        svix_signature
        |> String.split(" ")
        |> Enum.map(fn "v1," <> sig -> sig; sig -> sig end)

      if expected in incoming_signatures do
        :ok
      else
        {:error, :invalid_signature}
      end
    end
  end

  defp process_event(%{"type" => "email.bounced", "data" => data}) do
    Logger.warning("[Webhook] Bounce for #{inspect(data["to"])}: #{data["email_id"]}")
    # flag address in db, remove from mailing list, etc.
  end

  defp process_event(%{"type" => "email.complained", "data" => data}) do
    Logger.warning("[Webhook] Complaint for #{inspect(data["to"])}: #{data["email_id"]}")
  end

  defp process_event(%{"type" => type}) do
    Logger.debug("[Webhook] Unhandled Resend event: #{type}")
  end
end
```

Add the route (no CSRF protection for webhooks — they are not browser requests):

```elixir
# lib/code_my_spec_web/router.ex
scope "/webhooks" do
  pipe_through :api
  post "/resend", ResendWebhookController, :handle
end
```

### Replay attacks

Resend includes a timestamp. Reject requests where `abs(System.os_time(:second) - svix_timestamp_int) > 300` (5 minutes) to block replayed payloads.

### Deduplication

Store `svix-id` values in a DB table (or a short-lived Redis key) and return 200 immediately on duplicates without re-processing.
