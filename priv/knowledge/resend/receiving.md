# Resend Inbound (Receiving) Email

Resend can **receive** mail for a domain you control, persist each message
(body, headers, attachments, raw `.eml`), and POST a metadata-only
`email.received` webhook to you. We use this to back **story 816**: one domain
per project, mail routed to a **Mailbox** by its **To** address. We do **not**
store emails ourselves — Resend is the system of record and we query its API.

Base URL: `https://api.resend.com` — Auth: `Authorization: Bearer $RESEND_API_KEY`

Docs: [receiving/introduction](https://resend.com/docs/dashboard/receiving/introduction),
[custom-domains](https://resend.com/docs/dashboard/receiving/custom-domains),
[get-email-content](https://resend.com/docs/dashboard/receiving/get-email-content),
[blog/inbound-emails](https://resend.com/blog/inbound-emails).

## Quick reference

| Operation | Method + path |
|---|---|
| Webhook event for inbound mail | `email.received` (metadata only) |
| List received emails | `GET /emails/receiving` |
| Get a received email (body + headers) | `GET /emails/receiving/{id}` |
| List a received email's attachments | `GET /emails/receiving/{id}/attachments` |
| Get a sent email (outbound) | `GET /emails/{id}` |
| List sent emails (outbound) | `GET /emails` |

## How it maps to our model

- **Route by To.** Resend is wildcard: any address `*@yourdomain.tld` is
  received. Match each `to[]` address against `mailboxes (project_id, user_id)`.
- **Catch-all.** An address with no matching user mailbox → the project's
  shared **catch-all** mailbox (`user_id` NULL).
- **One domain per project.** The receiving domain is the project's domain; the
  webhook's `email_id` is the only durable handle — store it, not the body.
- **Threading.** Use the top-level `message_id` plus `In-Reply-To` /
  `References` from the `headers` object (see below) to group a conversation.
- **History = query Resend.** Mailbox views call `GET /emails/receiving` (inbound)
  and `GET /emails` (outbound), filtered in our code by mailbox address. We never
  persist message bodies in our DB.

Conventions: **hand-write the Req client** (no API-wrapper lib — see api.md /
MEMORY); **verify the webhook with a raw-body reader** (see webhooks.md / gotchas.md).

## 1. Enabling a receiving domain

Two options ([introduction](https://resend.com/docs/dashboard/receiving/introduction)):

1. **Resend-managed** — every account gets `*@<id>.resend.app` with no DNS. Good
   for dev/testing.
2. **Custom domain** — verify the domain, then enable receiving and add **one MX
   record** ([custom-domains](https://resend.com/docs/dashboard/receiving/custom-domains)).

Custom-domain flow:

1. Verify the domain (existing DKIM/SPF flow — see `../devops/cloudflare-resend-email-setup.md`).
2. On the domain's detail page, toggle **receiving** on.
3. Copy the **MX record** Resend shows and add it to DNS. Resend renders the exact
   host/priority/target in the dashboard (it is **not** published as a fixed value;
   read it per-domain via the Domains page or `GET /domains/{id}`).
4. Click "I've added the record" and wait for MX verification.

**Critical limits / gotchas:**

- The Resend MX record **must be the lowest-priority MX** for the host, or no mail
  is received ([custom-domains](https://resend.com/docs/dashboard/receiving/custom-domains)).
- If the root domain already has MX records (existing mail provider), put receiving
  on a **subdomain** (e.g. `inbound.yourdomain.tld`) to avoid hijacking real mail.
- Available on **all plans including Free** — inbound is not gated behind a paid
  tier ([pricing](https://resend.com/pricing)).

## 2. Inbound webhook — `email.received`

Register a webhook for the `email.received` event (dashboard → Webhooks, or
`POST /webhooks` — see webhooks.md). **The webhook payload is metadata only — no
body, no headers, no attachment bytes** ([get-email-content](https://resend.com/docs/dashboard/receiving/get-email-content)).
You must call the Receiving API to get content.

Payload shape ([blog/inbound-emails](https://resend.com/blog/inbound-emails)):

```json
{
  "type": "email.received",
  "created_at": "2026-04-03T22:13:42.674Z",
  "data": {
    "email_id": "56761188-7520-42d8-8898-ff6fc54ce618",
    "created_at": "2026-04-03T22:13:42.674Z",
    "from": "Acme <onboarding@resend.dev>",
    "to": ["support@yourdomain.tld"],
    "cc": [],
    "bcc": [],
    "subject": "Sending this example",
    "message_id": "<example+123>",
    "attachments": [
      {
        "filename": "avatar.png",
        "content_type": "image/png",
        "content_disposition": "inline",
        "content_id": "img001",
        "id": "2a0c9ce0-3112-4728-976e-47ddcd16a318",
        "size": 4096
      }
    ]
  }
}
```

**Signature verification** is identical to all other Resend webhooks — Svix
headers (`svix-id`, `svix-timestamp`, `svix-signature`), HMAC-SHA256 over
`"{svix-id}.{svix-timestamp}.{raw-body}"` with the Base64-decoded `whsec_` secret,
**requires the raw request body**. Use the same `CacheBodyReader` + controller
verification shown in **webhooks.md**. Dedup on `svix-id`; reject stale timestamps.

Our handler should: verify → on `email.received`, match each `data.to[]` address to
a Mailbox (or catch-all) → store the `email_id` (+ `message_id`, `from`, `subject`,
`created_at`) as a lightweight pointer → fetch body lazily on view.

## 3. Receiving API

### List received emails

```
GET /emails/receiving
```

Query params (cursor pagination — cannot use `after` and `before` together):

| Param | Notes |
|---|---|
| `limit` | default 20, min 1, max 100 |
| `after` | return emails after this id |
| `before` | return emails before this id |

```bash
curl -X GET 'https://api.resend.com/emails/receiving' \
  -H "Authorization: Bearer $RESEND_API_KEY"
```

Response ([list-received-emails](https://resend.com/docs/api-reference/emails/list-received-emails)):

```json
{
  "object": "list",
  "has_more": true,
  "data": [
    {
      "id": "string",
      "to": ["support@yourdomain.tld"],
      "from": "string",
      "created_at": "2026-04-03T22:13:42.674Z",
      "subject": "string",
      "cc": [],
      "bcc": [],
      "reply_to": [],
      "message_id": "<...>",
      "attachments": [
        { "id": "string", "filename": "string", "content_type": "string",
          "content_disposition": "string", "content_id": null, "size": 4096 }
      ]
    }
  ]
}
```

List does **not** include `text`/`html`/`headers` — fetch the single email for those.

### Get a received email (body + headers)

```
GET /emails/receiving/{id}
```

Optional `html_format` query param: `"data_uri"` (default, inline images embedded)
or `"cid"`.

```bash
curl -X GET 'https://api.resend.com/emails/receiving/4ef9a417-02e9-4d39-ad75-9611e0fcc33c' \
  -H "Authorization: Bearer $RESEND_API_KEY"
```

Response ([retrieve-received-email](https://resend.com/docs/api-reference/emails/retrieve-received-email)):

```json
{
  "object": "email",
  "id": "4ef9a417-02e9-4d39-ad75-9611e0fcc33c",
  "to": ["delivered@resend.dev"],
  "from": "onboarding@resend.dev",
  "created_at": "2026-04-03T22:13:42.674Z",
  "subject": "Hello World",
  "html": "Congrats on sending your <strong>first email</strong>!",
  "html_format": "data_uri",
  "text": null,
  "headers": {
    "from": "Acme <onboarding@resend.dev>",
    "return-path": "lucas.costa@resend.com",
    "mime-version": "1.0"
  },
  "cc": [],
  "bcc": [],
  "reply_to": [],
  "message_id": "<example+123>",
  "raw": {
    "download_url": "https://example.resend.com/receiving/raw/054da427-...?Signature=...",
    "expires_at": "2026-04-03T23:13:42.674Z"
  },
  "attachments": [
    { "id": "2a0c9ce0-3112-4728-976e-47ddcd16a318", "filename": "avatar.png",
      "content_type": "image/png", "content_disposition": "inline",
      "content_id": "img001", "size": 4096 }
  ]
}
```

**Threading fields:** the top-level `message_id` is the message's own id. The
`In-Reply-To` and `References` headers (when present) live inside the `headers`
**object** — `headers` is a flat lowercased key→value map, not an array. To thread:

```elixir
this_id   = email["message_id"]
parent_id = email["headers"]["in-reply-to"]
refs      = (email["headers"]["references"] || "") |> String.split(~r/\s+/, trim: true)
```

`raw.download_url` is a short-lived signed URL to the original `.eml` (`expires_at`
~1 hour out). Re-fetch the email to get a fresh URL; do not cache it.

### List attachments

```
GET /emails/receiving/{id}/attachments
```

Same `limit`/`after`/`before` pagination as the list endpoint (omit `limit` to get
all). Response items add a **signed CDN download URL** that expires:

```json
{
  "object": "list",
  "data": [
    {
      "id": "2a0c9ce0-3112-4728-976e-47ddcd16a318",
      "filename": "avatar.png",
      "content_type": "image/png",
      "content_disposition": "inline",
      "content_id": "img001",
      "size": 4096,
      "download_url": "https://inbound-cdn.resend.com/...?Signature=...",
      "expires_at": "2026-04-03T23:13:42.674Z"
    }
  ]
}
```

Fetch attachment bytes from `download_url` before `expires_at`; re-list to refresh.
([list-received-email-attachments](https://resend.com/docs/api-reference/emails/list-received-email-attachments))

## 4. Retention & limits

- **Retention: 30 days** on Free, Pro, and Scale; Enterprise is flexible
  ([pricing](https://resend.com/pricing)). After 30 days the message (and its
  body/attachments/raw) is gone from Resend. **Implication for story 816:** if a
  mailbox must show history older than 30 days, we have to persist it ourselves —
  the "query Resend, don't store" model only covers a 30-day window.
- **Plan:** receiving works on **all plans including Free** — no paid gate.
- **Inbound volume:** no published cap on received-email count or message size in
  the docs. Free plan's 100/day, 3,000/month caps are **send** limits, not receive.
- **API rate limit:** the standard **5 req/s team-wide** Resend cap applies to the
  receiving endpoints too (see api.md). List+lazy-fetch, don't fan out per message.
- **Signed URLs** (`raw.download_url`, attachment `download_url`) expire (~1h) —
  always re-fetch rather than persisting the URL.

## 5. Outbound retrieval (the other direction)

To show a mailbox's **sent** mail, query the outbound side by the same address:

```
GET /emails           # list sent emails (cursor pagination: limit/after/before)
GET /emails/{id}       # retrieve one sent email + last_event status
```

`GET /emails/{id}` returns the full sent record incl. `last_event` (`queued`,
`sent`, `delivered`, `bounced`, `complained`, `failed`, `scheduled`) — see api.md.
Filter both list endpoints by mailbox address in our code to assemble a single
per-mailbox timeline (inbound `GET /emails/receiving` + outbound `GET /emails`).

## Gotchas

- **Webhook ≠ content.** `email.received` carries metadata only. Never try to read
  `text`/`html`/`headers` off the webhook — call `GET /emails/receiving/{id}`.
- **MX priority.** Resend MX must be the **lowest priority** on the host or zero
  mail arrives, with no error surfaced.
- **Don't clobber real mail.** Put receiving on a subdomain if the root already has
  MX records.
- **`headers` is an object, not an array.** Keys are lowercased
  (`"in-reply-to"`, `"references"`, `"message-id"`). Different shape from the
  send-side `headers` body field — handle accordingly.
- **30-day cliff.** Resend purges inbound after 30 days; design mailbox history
  around that window or persist what must outlive it.
- **Expiring signed URLs.** `raw.download_url` and attachment `download_url` are
  short-lived — fetch immediately, never cache.
- **Same Svix verification.** Reuse the raw-body reader + HMAC check from
  webhooks.md; the `whsec_`-strip / Base64-decode gotchas in gotchas.md apply here
  unchanged.
