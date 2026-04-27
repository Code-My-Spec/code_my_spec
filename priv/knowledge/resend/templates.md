# Resend Templates

Resend-hosted templates let you manage email HTML in the Resend dashboard and send personalised email by passing variables from Elixir code. Templates are a good fit when non-engineers need to edit copy or layout without a deploy cycle.

## Variable syntax in the template editor

Variables use triple curly braces: `{{{VARIABLE_NAME}}}`.

```html
<p>Hi {{{FIRST_NAME}}},</p>
<p>Your invoice #{{{INVOICE_NUMBER}}} for ${{{AMOUNT}}} is ready.</p>
<p><a href="{{{INVOICE_URL}}}">View invoice</a></p>
```

Variables can appear in:
- Body (HTML and plain text)
- Subject line
- Reply-to
- Preview text

Each variable has a type (`string` or `number`) and an optional fallback value. If a variable is missing from the send request and has no fallback, Resend returns a `422 validation_error`.

## Creating and publishing templates

Templates must be published before they can be used for sending. Drafts are not accessible via the send API.

```bash
# CLI: create a template from a React Email file
resend templates create \
  --name "Invoice Receipt" \
  --subject "Your invoice #{{{INVOICE_NUMBER}}}" \
  --react-email ./email-templates/invoice.tsx

resend templates publish <id>

# List to find the template ID
resend templates list

# Update and republish
resend templates update <id> --react-email ./email-templates/invoice.tsx
resend templates publish <id>
```

## Sending via Swoosh

Use `put_provider_option(:template, ...)`. You cannot include `html_body` or `text_body` in the same email — they are mutually exclusive.

```elixir
import Swoosh.Email

def deliver_invoice_receipt(user, invoice) do
  new()
  |> to(user.email)
  |> from({"CodeMySpec", "contact@codemyspec.com"})
  |> subject("Your invoice ##{invoice.number}")   # overrides template subject
  |> put_provider_option(:template, %{
       id: "tpl_invoice_receipt",                  # template ID or alias
       variables: %{
         "FIRST_NAME"      => user.first_name || "there",
         "INVOICE_NUMBER"  => to_string(invoice.number),
         "AMOUNT"          => :erlang.float_to_binary(invoice.amount_usd, decimals: 2),
         "INVOICE_URL"     => "https://codemyspec.com/invoices/#{invoice.id}"
       }
     })
  |> CodeMySpec.Mailer.deliver()
end
```

Note: variable values must be strings or numbers. Convert Elixir decimals/integers explicitly.

## Sending via the REST API

```bash
curl -sS -X POST https://api.resend.com/emails \
  -H "Authorization: Bearer $RESEND_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "from": "CodeMySpec <contact@codemyspec.com>",
    "to": ["user@example.com"],
    "subject": "Your invoice #1042",
    "template": {
      "id": "tpl_invoice_receipt",
      "variables": {
        "FIRST_NAME": "Alice",
        "INVOICE_NUMBER": "1042",
        "AMOUNT": "49.00",
        "INVOICE_URL": "https://codemyspec.com/invoices/abc"
      }
    }
  }'
```

## Template ID vs alias

The Resend dashboard lets you set a human-readable alias (e.g., `invoice_receipt`) in addition to the auto-generated `tpl_xxx` ID. Use the alias in code so it stays stable if you delete and recreate the template.

## Limitations

| Constraint | Detail |
|---|---|
| Mutually exclusive fields | `template` cannot appear alongside `html`, `text`, or `react` |
| Variable types | String or number only; no arrays or nested objects |
| Missing variables | 422 error if variable has no value and no fallback |
| Batch send | Templates work in batch (`POST /emails/batch`) |
| `scheduled_at` in batch | Not supported |
| Publishing required | Drafts cannot be sent |

## When to use templates vs inline HTML

Use Resend-hosted templates when:
- Marketing or design team edits email copy independently
- You want a visual preview in the Resend dashboard

Use inline Swoosh `html_body` when:
- The content is fully dynamic and generated from Elixir data
- You want to test the exact rendered HTML in ExUnit (easier with inline bodies)
- You need to avoid an external dependency for CI
