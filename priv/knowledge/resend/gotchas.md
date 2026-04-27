# Resend — Gotchas and Common Failures

Practical failure modes, their causes, and fixes.

## `(RuntimeError) :api_client is not set`

**Cause**: `Swoosh.ApiClient.Req` is configured in `prod.exs` but not in `dev.exs`. In dev the local adapter is used, which does not need an HTTP client. If you run a prod-like mix task locally without the correct env, Swoosh panics.

**Fix**: This is already correct in this project. Do not add `api_client: Swoosh.ApiClient.Req` to `dev.exs` — it should only be in `prod.exs`.

## `403 The domain is not verified`

**Cause**: The `from` address domain does not match any verified domain in Resend. Subdomain senders (e.g., `notifications@mail.codemyspec.com`) require that subdomain to be verified separately.

**Fix**: Use `contact@codemyspec.com` or another address under a verified domain. Run `resend domains list` to see what is verified.

## `403 You can only send testing emails to your own email address`

**Cause**: Resend restricts new accounts or accounts with no verified domain to sending to the account owner's email address only.

**Fix**: Verify a domain. Until then, the only valid `to` address is the account email. Do not use `onboarding@resend.dev` as the `from` in production — it is for Resend's own quick-start testing only.

## Emails stuck in `pending` / domain stuck `pending`

**Cause**: DNS change not yet propagated, or the DKIM TXT record was entered with extra whitespace or quotes that broke the key.

**Fix**:
1. Verify with `dig`: `dig +short TXT resend._domainkey.codemyspec.com`
2. Compare against the value shown in `resend domains get <id>`
3. Once DNS is correct, run `resend domains verify <id>` to re-trigger verification
4. Cloudflare propagates within seconds; the issue is almost always the record content

## Emails delivered but going to spam

Likely causes, in order:
1. DMARC policy missing or `p=none` — add a DMARC record and monitor alignment
2. Bounce or complaint rate too high — check Resend analytics; rates above 4% / 0.08% trigger throttling
3. No plain-text body — always set `text_body` alongside `html_body`
4. Link-heavy HTML with no real content — ensure text/link ratio is reasonable

## Dev mailbox is empty

**Cause**: The local adapter stores emails in the process that called `Mailer.deliver/1`. If the endpoint is not running in dev with `dev_routes: true`, the mailbox preview route is not mounted.

**Fix**: Ensure `config/dev.exs` has `adapter: Swoosh.Adapters.Local` (it does by default) and that your router has:

```elixir
if Application.compile_env(:code_my_spec, :dev_routes) do
  forward "/dev/mailbox", Swoosh.MailboxPreview
end
```

## `assert_email_sent` passes when running solo but fails in the full suite

**Cause**: `Swoosh.Adapters.Test` uses the process mailbox. When email is sent from a spawned process (LiveView, Task, Oban worker), the assertion in the test process sees nothing.

**Fix**: Use `async: false` and `setup :set_swoosh_global` — see `swoosh.md`.

## Rate limit (429) on burst sends

**Cause**: All API keys share a 5 req/s team-wide limit. Iterating over a list and calling `Mailer.deliver/1` in a tight loop will hit this.

**Fix**: Use `Mailer.deliver_many/1` to batch up to 100 emails per call. For larger volumes, queue with Oban and set a rate-limited worker:

```elixir
use Oban.Worker, queue: :email, max_attempts: 3

# config/config.exs
config :code_my_spec, Oban,
  queues: [email: [limit: 5, rate_limit: [period: 1, allowed: 5]]]
```

## `422 invalid_attachment` — attachment has neither content nor path

**Cause**: A `Swoosh.Attachment` struct was built with both `content` and `path` as nil, or with a zero-byte binary.

**Fix**: Pass either the file binary as `data:` or a publicly accessible `path:` URL. Never both.

## Template variables returning `422 validation_error`

**Cause**: A variable referenced in the template body has no value in the `variables` map and no fallback value set in the template editor.

**Fix**: Supply all variables explicitly, or open the template in the Resend dashboard and set fallback values. Convert all Elixir non-string types to strings before passing:

```elixir
variables: %{
  "AMOUNT" => :erlang.float_to_binary(invoice.amount_usd / 100, decimals: 2),
  "COUNT"  => Integer.to_string(count)
}
```

## `html_body` alongside `template` provider option

**Cause**: The email struct has `html_body` set (e.g., from a `|> html_body(...)` call) and also `put_provider_option(:template, ...)`. Resend treats these as mutually exclusive.

**Fix**: When using templates, do not call `text_body/2` or `html_body/2`. Build the email with only `to`, `from`, `subject` (optional — template may provide a default), and the template provider option.

## Webhook signature verification fails on every request

Most common causes:

1. **Raw body not preserved** — the plug parser consumed the body before your controller read it. Implement `CacheBodyReader` as shown in `webhooks.md`.
2. **`whsec_` prefix not stripped** — the HMAC key must be the Base64-decoded portion after `whsec_`. Passing the full secret string as the key produces a wrong signature.
3. **Base64 padding issue** — `Base.decode64!/1` in Elixir requires properly padded Base64. If the secret has padding stripped, use `Base.decode64!(secret, padding: false)`.
4. **Timestamp in wrong format** — the `svix-timestamp` header is a Unix timestamp in seconds (integer string), not ISO 8601.

## `RESEND_API_KEY` is set but emails are not sending in prod

Check in order:
1. `resend whoami` — confirm the key matches what is in the env
2. `resend doctor` — runs automated diagnostics
3. Look for `api_key: ""` in the runtime config — Dotenvy returns `""` for missing vars with the `""` default; the Swoosh adapter treats an empty key as unauthenticated
4. Check Resend dashboard → Logs for the attempted send

## `monthly_quota_exceeded` / `daily_quota_exceeded`

Free plan caps: 100/day, 3,000/month. Either upgrade the plan or implement send-rate tracking before calling `Mailer.deliver/1`.
