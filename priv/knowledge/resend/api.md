# Resend REST API

Direct HTTP reference for the Resend API. Use this when calling Resend outside of Swoosh — diagnostics, background jobs, admin scripts, or features Swoosh does not expose (batch send, email cancellation, contact/audience management).

Base URL: `https://api.resend.com`
Auth header: `Authorization: Bearer $RESEND_API_KEY`

## Send a single email

```
POST /emails
```

### Required body fields

| Field | Type | Notes |
|---|---|---|
| `from` | string | `"Name <addr@domain.com>"` or bare address. Domain must be verified. |
| `to` | string \| string[] | Up to 50 addresses |
| `subject` | string | |

### Optional body fields

| Field | Type | Notes |
|---|---|---|
| `html` | string | HTML body |
| `text` | string | Plain text body. Auto-derived from HTML if omitted. |
| `cc` | string \| string[] | |
| `bcc` | string \| string[] | |
| `reply_to` | string \| string[] | |
| `scheduled_at` | string | ISO 8601 or natural language (`"in 1 min"`) |
| `tags` | array | `[{"name":"env","value":"prod"}]`. ASCII alphanum + `_` `-`, max 256 chars each. |
| `headers` | object | Custom SMTP headers |
| `attachments` | array | See below |
| `template` | object | `{"id":"tpl_xxx","variables":{"KEY":"value"}}`. Mutually exclusive with `html`/`text`. |
| `topic_id` | string | Subscription management |

### Attachments structure

```json
{
  "filename": "report.pdf",
  "content": "<base64-encoded-bytes>",
  "content_type": "application/pdf",
  "content_id": "cid-report"
}
```

- `content` or `path` (a hosted URL) must be present — not both
- `content_id` enables inline images (`<img src="cid:cid-report">`)
- 40 MB total attachment limit per email after Base64 encoding

### Idempotency

Pass `Idempotency-Key: <unique-string>` in the request header to prevent duplicate sends on network retries. The key is valid for 24 hours and must be 1–256 characters. Reusing the same key with a different body returns HTTP 409.

### Response

```json
{ "id": "49a3999c-0ce1-4ea6-ab68-afcd6dc2e794" }
```

### curl example

```bash
curl -sS -X POST https://api.resend.com/emails \
  -H "Authorization: Bearer $RESEND_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "from": "CodeMySpec <contact@codemyspec.com>",
    "to": ["you@example.com"],
    "subject": "Hello",
    "text": "Plain text body."
  }'
```

## Batch send (up to 100 emails)

```
POST /emails/batch
```

Body: a JSON array of email objects with the same fields as single send. Response: `{"data":[{"id":"..."},{"id":"..."}]}`.

Batch does not support `scheduled_at` or `attachments`.

## Retrieve email status

```
GET /emails/{id}
```

Returns the full email record including `last_event` (one of: `queued`, `sent`, `delivered`, `bounced`, `complained`, `failed`, `scheduled`).

## Update a scheduled email

```
PATCH /emails/{id}
```

Only `scheduled_at` can be updated. The email must still be in `scheduled` state.

## Cancel a scheduled email

```
POST /emails/{id}/cancel
```

The email must be in `scheduled` state. Returns `{"object":"email","id":"..."}`.

## API keys

```
POST   /api-keys           # create
GET    /api-keys           # list
DELETE /api-keys/{id}      # revoke
```

Create body: `{"name":"ci-sender","permission":"sending_access","domain_id":"<optional>"}`.
Permissions: `"full_access"` or `"sending_access"`.

## Domains

```
POST   /domains            # add domain {"name":"yourdomain.com","region":"us-east-1"}
GET    /domains            # list
GET    /domains/{id}       # get with DNS records
POST   /domains/{id}/verify  # trigger verification
DELETE /domains/{id}
```

Regions: `us-east-1`, `eu-west-1`, `sa-east-1`.

## Error codes

| Status | Name | Meaning |
|---|---|---|
| 400 | `validation_error` | Missing or malformed field |
| 400 | `invalid_idempotency_key` | Key outside 1–256 chars |
| 401 | `missing_api_key` | No Authorization header |
| 401 | `restricted_api_key` | Key lacks permission for this action |
| 403 | `invalid_api_key` | Key does not exist or is revoked |
| 403 | `validation_error` | Domain not verified; or test-mode address restriction |
| 404 | `not_found` | Endpoint or resource does not exist |
| 405 | `method_not_allowed` | Wrong HTTP method |
| 409 | `invalid_idempotent_request` | Same key, different payload |
| 409 | `concurrent_idempotent_requests` | Same key reused before original resolved |
| 422 | `invalid_attachment` | Attachment has neither `content` nor `path` |
| 422 | `invalid_from_address` | Sender address format invalid |
| 422 | `missing_required_field` | `from`, `to`, or `subject` missing |
| 422 | `invalid_region` | Region not in allowed list |
| 429 | `rate_limit_exceeded` | Over 5 req/s team-wide |
| 429 | `daily_quota_exceeded` | Free-plan 100/day limit hit |
| 429 | `monthly_quota_exceeded` | Plan monthly cap hit |
| 451 | `security_error` | Potential security issue detected |
| 500 | `application_error` | Unexpected server error |

Error response body:

```json
{
  "name": "validation_error",
  "message": "The domain is not verified.",
  "statusCode": 403
}
```

## Rate limits and quotas

| Plan | Rate | Daily cap | Monthly cap |
|---|---|---|---|
| All plans | 5 req/s (team-wide) | — | — |
| Free | 5 req/s | 100 emails | 3,000 emails |
| Pro | 5 req/s | None | 50,000 emails |
| Scale | 5 req/s | None | 100,000 emails |

The 5 req/s cap applies to the whole team, not per API key. Use batch send to stay under the limit when sending bursts. Contact support to request a higher rate limit. Paid plans allow pay-as-you-go overages up to 5x the monthly quota before sending pauses.

Quality floors: bounce rate < 4%, spam rate < 0.08%.
