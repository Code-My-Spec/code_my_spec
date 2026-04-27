# Cloudflare + Resend Email Setup

How to configure transactional email for a Phoenix app using **Resend** as the provider with a domain on **Cloudflare DNS**. Outbound only — for inbound, see Cloudflare Email Routing or Resend Inbound separately.

> **As of 2026-04-26**, Resend's verification flow uses a `send` subdomain pointing at Amazon SES (their underlying transport) plus a single DKIM TXT. Older guides describing three `resend*._domainkey` CNAMEs and an apex SPF `include:send.resend.com` are stale.

## Overview

- **Email provider**: [Resend](https://resend.com) — API-based transactional email
- **DNS provider**: Cloudflare — manages SPF/DKIM/DMARC for the sending domain
- **Elixir library**: [Swoosh](https://hexdocs.pm/swoosh) with `Swoosh.Adapters.Resend`
- **API client**: `Swoosh.ApiClient.Req` (Req is already in the project)

## 1. Resend account & API key

1. Sign up at [resend.com](https://resend.com)
2. **API Keys** → **Create API Key**, name it after the env (e.g. `code-my-spec-prod`)
3. Copy the key — starts with `re_`
4. Store in your env secrets file:

   ```bash
   RESEND_API_KEY=re_your_api_key_here
   ```

## 2. Add the domain in Resend

Either via dashboard (**Domains** → **Add Domain**) or API:

```bash
curl -sS -X POST https://api.resend.com/domains \
  -H "Authorization: Bearer $RESEND_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"name":"yourdomain.com","region":"us-east-1"}'
```

The response includes a domain `id` and a `records` array — three records to publish in DNS.

## 3. Add DNS records in Cloudflare

The actual record set depends on your Resend region. For `us-east-1` you'll get:

| Type | Name | Content | Priority | Proxy |
|------|------|---------|----------|-------|
| TXT | `resend._domainkey` | DKIM key from Resend response (`p=MIGf...`) | — | N/A |
| MX | `send` | `feedback-smtp.us-east-1.amazonses.com` | 10 | N/A |
| TXT | `send` | `v=spf1 include:amazonses.com ~all` | — | N/A |

> **EU region**: hostname is `feedback-smtp.eu-west-1.amazonses.com` and SPF stays `include:amazonses.com`. Other regions follow the same pattern.

> The DKIM and `send` SPF/MX records do not affect any existing apex mail records — Resend uses `send.yourdomain.com` as the bounce/Return-Path subdomain, which provides DMARC alignment via DKIM (`d=yourdomain.com`) without touching apex MX.

### Apex SPF (optional but recommended)

If your apex has no other senders, set an explicit reject so spoofers can't impersonate `@yourdomain.com`:

```
TXT @ "v=spf1 -all"
```

Resend mail still passes DMARC because DKIM signs with `d=yourdomain.com` (aligned with the From header).

### DMARC (recommended)

```
TXT _dmarc "v=DMARC1; p=none; rua=mailto:dmarc@yourdomain.com"
```

Start with `p=none` to monitor, tighten to `p=quarantine` then `p=reject` once you've confirmed Resend mail is aligned.

### Doing it via Cloudflare API

If you have a Cloudflare API token with `Zone:DNS:Edit`:

```bash
ZONE=$(curl -sS "https://api.cloudflare.com/client/v4/zones?name=yourdomain.com" \
  -H "Authorization: Bearer $CF_TOKEN" | jq -r '.result[0].id')

# DKIM
curl -sS -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records" \
  -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" \
  -d '{"type":"TXT","name":"resend._domainkey","content":"<dkim-from-resend>","ttl":1,"proxied":false}'

# Bounce subdomain MX
curl -sS -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records" \
  -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" \
  -d '{"type":"MX","name":"send","content":"feedback-smtp.us-east-1.amazonses.com","priority":10,"ttl":1}'

# Bounce subdomain SPF
curl -sS -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records" \
  -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" \
  -d '{"type":"TXT","name":"send","content":"v=spf1 include:amazonses.com ~all","ttl":1,"proxied":false}'
```

## 4. Trigger verification

Cloudflare propagates within seconds; resolvers may negative-cache. Trigger Resend's verifier and poll:

```bash
DOMAIN_ID=<id from step 2>

curl -sS -X POST "https://api.resend.com/domains/$DOMAIN_ID/verify" \
  -H "Authorization: Bearer $RESEND_API_KEY"

# Poll status (typically clears in 1–10 minutes)
curl -sS "https://api.resend.com/domains/$DOMAIN_ID" \
  -H "Authorization: Bearer $RESEND_API_KEY" | jq '{status, records: [.records[] | {type, name, status}]}'
```

When `status: "verified"` you can send from any address `@yourdomain.com`.

## 5. Configure the Phoenix app

### Mailer module

```elixir
# lib/code_my_spec/mailer.ex
defmodule CodeMySpec.Mailer do
  use Swoosh.Mailer, otp_app: :code_my_spec
end
```

### Config: dev (`config/dev.exs`)

```elixir
config :code_my_spec, CodeMySpec.Mailer, adapter: Swoosh.Adapters.Local
config :swoosh, :api_client, false
```

Local mailbox at `/dev/mailbox` (when `dev_routes: true`).

### Config: test (`config/test.exs`)

```elixir
config :code_my_spec, CodeMySpec.Mailer, adapter: Swoosh.Adapters.Test
config :swoosh, :api_client, false
```

### Config: prod (`config/prod.exs`)

```elixir
config :swoosh, api_client: Swoosh.ApiClient.Req
```

### Config: runtime (`config/runtime.exs`)

```elixir
if config_env() == :prod do
  config :code_my_spec, CodeMySpec.Mailer,
    adapter: Swoosh.Adapters.Resend,
    api_key: env!("RESEND_API_KEY", :string, "")
end
```

### Docker Compose / env passthrough

```yaml
services:
  app:
    environment:
      RESEND_API_KEY: ${RESEND_API_KEY:-}
```

## 6. Sending

```elixir
import Swoosh.Email

new()
|> to("user@example.com")
|> from({"CodeMySpec", "contact@codemyspec.com"})
|> subject("Welcome!")
|> text_body("Hello.")
|> CodeMySpec.Mailer.deliver()
```

The `from` address must use a verified domain.

## 7. Migrating from Mailgun (or other Swoosh adapters)

The Swoosh API is adapter-agnostic — only the runtime config changes. From Mailgun:

```diff
 config :code_my_spec, CodeMySpec.Mailer,
-  adapter: Swoosh.Adapters.Mailgun,
-  api_key: System.get_env("MAILGUN_API_KEY"),
-  domain: System.get_env("MAILGUN_DOMAIN")
+  adapter: Swoosh.Adapters.Resend,
+  api_key: env!("RESEND_API_KEY", :string, "")
```

Then clean stale DNS:

| Record | Action |
|--------|--------|
| `CNAME email.<domain> → mailgun.org` | Delete (Mailgun click-tracking) |
| `TXT smtp._domainkey.<domain>` | Delete (Mailgun DKIM) |
| `TXT @ "v=spf1 include:mailgun.org ~all"` | Delete or replace with `v=spf1 -all` |
| `MX @ → mxa/mxb.mailgun.org` | **Don't delete blindly** — these are inbound. Decide where receiving goes first (Cloudflare Email Routing, Resend Inbound, or kill entirely). |

## 8. Troubleshooting

| Issue | Fix |
|-------|-----|
| Emails not sending in prod | `RESEND_API_KEY` is set and non-empty |
| Domain stuck `pending` past 10 min | Re-verify each record with `dig +short <type> <name> @<authoritative-ns>`; common cause is typoed DKIM TXT |
| `(RuntimeError) :api_client is not set` | Add `config :swoosh, api_client: Swoosh.ApiClient.Req` to `prod.exs` |
| Mail goes to spam | Add DMARC, confirm `send` MX/SPF + DKIM all show `verified` in Resend |
| `403 Domain is not verified` from Resend | The `from` address domain must match a verified Resend domain (or subdomain) |
| Dev mailbox empty | Set `dev_routes: true` and visit `/dev/mailbox` |

## References

- Resend domain verification — https://resend.com/docs/dashboard/domains/introduction
- Swoosh Resend adapter — https://hexdocs.pm/swoosh/Swoosh.Adapters.Resend.html
- Project usage knowledge — `priv/knowledge/resend/`
