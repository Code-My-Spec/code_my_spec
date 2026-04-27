# Resend CLI

The official Resend CLI (`resend`) is the fastest way to test sending, manage domains, rotate keys, and inspect webhooks from a terminal or CI step — without writing any Elixir.

## Installation

```bash
# macOS
brew install resend/cli/resend

# npm (cross-platform)
npm install -g resend-cli
```

## Authentication

```bash
resend login          # prompts for API key, stores securely
resend whoami         # verify which key / profile is active
resend logout         # remove saved key

# Multiple environments (dev, prod)
resend auth list
resend auth switch
```

Override for a single command without modifying stored credentials:

```bash
resend --api-key re_xxxx emails list
```

## Sending emails

```bash
# Plain text
resend emails send \
  --from "CodeMySpec <contact@codemyspec.com>" \
  --to you@example.com \
  --subject "Test from CLI" \
  --text "Hello from the terminal."

# HTML body (pass file path)
resend emails send \
  --from "CodeMySpec <contact@codemyspec.com>" \
  --to you@example.com \
  --subject "Rich test" \
  --html "<h1>Hello</h1><p>From the CLI.</p>"

# Scheduled send (ISO 8601 or natural language)
resend emails send \
  --from "CodeMySpec <contact@codemyspec.com>" \
  --to you@example.com \
  --subject "Scheduled" \
  --text "See you tomorrow." \
  --scheduled-at "in 24 hours"

# Batch send from JSON file (max 100)
resend emails batch --file batch.json
```

`batch.json` format:

```json
[
  {"from":"contact@codemyspec.com","to":"a@example.com","subject":"Batch 1","text":"Hello A"},
  {"from":"contact@codemyspec.com","to":"b@example.com","subject":"Batch 2","text":"Hello B"}
]
```

## Managing sent mail

```bash
resend emails list                 # recent outbox
resend emails get <id>             # full details + status
resend emails cancel <id>          # cancel a scheduled send
resend emails update <id> --scheduled-at "in 2 hours"
```

## Domain management

```bash
# Add a new sending domain
resend domains create --name yourdomain.com --region us-east-1

# List all domains + verification status
resend domains list

# Get DNS records for a specific domain
resend domains get <id>

# Trigger re-verification (after updating DNS)
resend domains verify <id>

# Remove a domain
resend domains delete <id>
```

## API key management

```bash
resend api-keys create --name "prod-2026-04" --permission sending_access
resend api-keys list
resend api-keys delete <id>
```

Permissions:
- `full_access` — create, delete, get, update any resource
- `sending_access` — send only; optionally lock to one domain with `--domain-id <id>`

## Webhook management

```bash
# Register an endpoint
resend webhooks create \
  --endpoint https://yourapp.com/webhooks/resend \
  --events email.delivered,email.bounced,email.complained

# Local development tunnel (proxies to localhost)
resend webhooks listen \
  --url http://localhost:4000/webhooks/resend \
  --events email.delivered,email.bounced

resend webhooks list
resend webhooks get <id>           # includes signing secret
resend webhooks delete <id>
```

## Diagnostics

```bash
resend doctor          # verify auth, domain status, API reachability
resend doctor --json   # structured output for scripting
resend open            # open Resend dashboard in browser
resend update          # check for CLI updates
```

## Global flags (all commands)

| Flag | Description |
|---|---|
| `--api-key <key>` | Override stored credential |
| `--profile <name>` | Use named profile |
| `--json` | Machine-readable JSON output |
| `--quiet` | Suppress status spinners and tables |
| `--help` | Command-specific help |
