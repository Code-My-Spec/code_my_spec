# Swoosh + Resend in Elixir

How to compose, deliver, and test email in this project using Swoosh with the Resend adapter.

## What is already configured

The project ships with a working email stack. The config is spread across three files:

**`config/config.exs`** — default adapter for all envs not overridden:
```elixir
config :code_my_spec, CodeMySpec.Mailer, adapter: Swoosh.Adapters.Local
```

**`config/test.exs`**:
```elixir
config :code_my_spec, CodeMySpec.Mailer, adapter: Swoosh.Adapters.Test
config :swoosh, :api_client, false
```

**`config/prod.exs`**:
```elixir
config :swoosh, api_client: Swoosh.ApiClient.Req
config :swoosh, local: false
```

**`config/runtime.exs`** (prod block):
```elixir
config :code_my_spec, CodeMySpec.Mailer,
  adapter: Swoosh.Adapters.Resend,
  api_key: env!("RESEND_API_KEY", :string, "")
```

**`lib/code_my_spec/mailer.ex`**:
```elixir
defmodule CodeMySpec.Mailer do
  use Swoosh.Mailer, otp_app: :code_my_spec
end
```

You do not need to change any of this to add new email types.

## Writing a notifier module

Follow the pattern in `UserNotifier` and `InvitationNotifier`. One module per domain concept, one function per email type.

```elixir
defmodule CodeMySpec.Billing.BillingNotifier do
  @moduledoc false
  import Swoosh.Email

  alias CodeMySpec.Mailer

  def deliver_receipt(user, invoice) do
    new()
    |> to(user.email)
    |> from({"CodeMySpec", "contact@codemyspec.com"})
    |> subject("Your receipt for invoice ##{invoice.number}")
    |> text_body(receipt_text(invoice))
    |> html_body(receipt_html(invoice))
    |> Mailer.deliver()
  end

  defp receipt_text(invoice) do
    """
    Hi,

    Your payment of $#{invoice.amount_usd} for invoice ##{invoice.number} was received.

    Thanks,
    CodeMySpec
    """
  end

  defp receipt_html(invoice) do
    "<p>Your payment of $#{invoice.amount_usd} for invoice ##{invoice.number} was received.</p>"
  end
end
```

Rules:
- `from` address must use `codemyspec.com` — the verified domain
- Include both `text_body` and `html_body` when sending rich email; plain text is the fallback for deliverability
- Keep business logic in the context; the notifier is pure email composition + delivery

## Swoosh.Email struct fields

```elixir
%Swoosh.Email{
  to:          [{"Name", "addr@example.com"}],  # or bare "addr@example.com"
  from:        {"CodeMySpec", "contact@codemyspec.com"},
  cc:          [],
  bcc:         [],
  reply_to:    nil,
  subject:     "...",
  text_body:   "...",
  html_body:   "<p>...</p>",
  headers:     %{},
  attachments: [],
  assigns:     %{},
  provider_options: %{}
}
```

## Resend-specific provider options

Pass through `put_provider_option/3`:

```elixir
email
|> put_provider_option(:tags, [%{name: "type", value: "receipt"}])
|> put_provider_option(:scheduled_at, "2026-05-01T09:00:00Z")
|> put_provider_option(:idempotency_key, "invoice-#{invoice.id}")
```

| Option | Type | Notes |
|---|---|---|
| `:tags` | list of maps | `[%{name: "k", value: "v"}]`. Max 256 chars, ASCII alphanum + `_` `-` |
| `:scheduled_at` | string | ISO 8601 or natural language (`"in 1 hour"`) |
| `:idempotency_key` | string | Prevents duplicate sends. 1–256 chars, expires in 24 h |
| `:template` | map | `%{id: "tpl_xxx", variables: %{"KEY" => "value"}}` — see `templates.md` |

## Attachments

```elixir
email
|> attachment("/abs/path/to/file.pdf")
|> attachment(%Swoosh.Attachment{
     filename: "report.pdf",
     content_type: "application/pdf",
     data: File.read!("/path/to/report.pdf")
   })
```

## Batch delivery

`Mailer.deliver_many/1` sends up to 100 emails in a single API call:

```elixir
emails = Enum.map(users, fn user ->
  new()
  |> to(user.email)
  |> from({"CodeMySpec", "contact@codemyspec.com"})
  |> subject("Digest")
  |> text_body("Your weekly digest.")
end)

Mailer.deliver_many(emails)
```

Batch does not support `scheduled_at` or attachments. Use individual `deliver/1` calls if you need those.

## Testing

The test adapter (`Swoosh.Adapters.Test`) captures emails in the test process mailbox. Import `Swoosh.TestAssertions` to get assertions.

```elixir
defmodule CodeMySpec.Billing.BillingNotifierTest do
  use CodeMySpec.DataCase, async: true
  import Swoosh.TestAssertions

  alias CodeMySpec.Billing.BillingNotifier

  test "deliver_receipt/2 sends a receipt email" do
    user = user_fixture()
    invoice = invoice_fixture(user)

    BillingNotifier.deliver_receipt(user, invoice)

    assert_email_sent(
      to: [{"", user.email}],
      subject: "Your receipt for invoice ##{invoice.number}"
    )
  end

  test "deliver_receipt/2 does not send to wrong address" do
    user = user_fixture()
    invoice = invoice_fixture(user)

    BillingNotifier.deliver_receipt(user, invoice)

    refute_email_sent(to: [{"", "other@example.com"}])
  end
end
```

### Assertion functions

| Function | Description |
|---|---|
| `assert_email_sent()` | Any email was sent |
| `assert_email_sent(email)` | Specific `%Swoosh.Email{}` was sent |
| `assert_email_sent(fields)` | Email matching keyword list was sent |
| `assert_email_sent(fn e -> ... end)` | Email satisfying predicate was sent |
| `assert_emails_sent(list)` | All emails in list were sent |
| `assert_no_email_sent()` | No email was sent |
| `refute_email_sent()` | Same as `assert_no_email_sent/0` |
| `assert_email_not_sent(email)` | Specific email was not sent |
| `refute_email_sent(fields)` | No email matching fields was sent |

### Cross-process / LiveView tests

When the email is sent from a process other than the test process (a LiveView action, a GenServer, an Oban job), the process-mailbox approach fails. Switch to global mode — but note this forces `async: false`:

```elixir
defmodule CodeMySpec.SomeFeatureTest do
  use CodeMySpec.DataCase, async: false   # required for global mode
  import Swoosh.TestAssertions

  setup :set_swoosh_global

  test "sending an invitation triggers a welcome email" do
    # ... drive the feature ...
    assert_email_sent(subject: "Welcome to ...")
  end
end
```

## Dev mailbox

In `dev`, the local adapter stores emails in memory. Visit `/dev/mailbox` to inspect them. This requires `plug Swoosh.MailboxPreview` in your router — Phoenix generators add this under `dev_routes: true`.
