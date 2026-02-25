# QA Tooling Patterns

Guide for writing QA test infrastructure for Phoenix apps. Covers authenticated curl scripts, seed data scripts, and smoke tests.

## Authenticated curl (session-based auth)

Phoenix uses CSRF tokens + session cookies. Curl needs a 3-step flow: fetch CSRF, POST login, reuse cookie jar.

### Reference script: `authenticated_curl.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

# --- Config (override via env vars) ---
BASE_URL="${APP_URL:-http://localhost:4000}"
EMAIL="${APP_EMAIL:-qa@example.com}"
PASS="${APP_PASS:-hello world!}"
COOKIE_JAR="/tmp/app_qa_cookies.txt"

# --- Login ---
login() {
  # Fetch CSRF token from login page
  CSRF=$(curl -s -c "$COOKIE_JAR" "$BASE_URL/users/log-in" \
    | grep -o 'name="_csrf_token"[^>]*value="[^"]*"' \
    | grep -o 'value="[^"]*"' \
    | cut -d'"' -f2)

  if [ -z "$CSRF" ]; then
    echo "ERROR: Could not extract CSRF token from $BASE_URL/users/log-in" >&2
    exit 1
  fi

  # URL-encode the CSRF token (contains +, /, = characters)
  ENCODED_CSRF=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$CSRF'))")

  # POST login
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
    -X POST "$BASE_URL/users/log-in" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "_csrf_token=$ENCODED_CSRF&user[email]=$EMAIL&user[password]=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$PASS'))")")

  if [ "$HTTP_CODE" != "302" ]; then
    echo "ERROR: Login failed (HTTP $HTTP_CODE)" >&2
    exit 1
  fi

  echo "Logged in as $EMAIL" >&2
}

# --- Main ---
# Login if no valid cookie jar exists
if [ ! -f "$COOKIE_JAR" ]; then
  login
else
  # Test if session is still valid
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIE_JAR" "$BASE_URL/users/settings")
  if [ "$HTTP_CODE" = "302" ]; then
    login
  fi
fi

# Pass remaining args to curl with the cookie jar
if [ $# -gt 0 ]; then
  curl -b "$COOKIE_JAR" "$@"
fi
```

### Key details

- CSRF token contains `+`, `/`, `=` — must be URL-encoded in form data
- Cookie jar needs both `-b` (send) and `-c` (save) on the login request
- Login returns 302 on success — don't follow the redirect during auth
- Session validity: try hitting an authenticated route, re-login on 302
- LiveView pages return HTML on first load (server-rendered), then upgrade to WebSocket

### API key auth (simpler)

For API endpoints with header-based auth, no script needed — just document the curl:

```bash
curl -X POST http://localhost:4000/api/endpoint \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: the_key" \
  -d '{"field": "value"}'
```

## Seed data scripts (.exs)

Seed scripts go in `priv/repo/` and run via `mix run priv/repo/qa_seeds.exs`. Each script boots the BEAM once and runs all seed logic in-process.

### Why `.exs`, not bash

A bash script that calls `mix run -e '...'` per entity boots the entire Elixir application from scratch each time — compiling, connecting to the database, starting supervision trees. For 9 entities, that's 9 full boots. A single `.exs` script does it in one.

### Reference script: `priv/repo/qa_seeds.exs`

```elixir
# priv/repo/qa_seeds.exs
#
# Creates a complete QA test dataset.
# Idempotent — safe to run multiple times.
#
# Usage: mix run priv/repo/qa_seeds.exs

alias MyApp.{Accounts, Repo}
alias MyApp.Accounts.User

# --- Helper ---
defmodule QaSeed do
  def find_or_create(queryable, unique_field, unique_value, create_fn) do
    import Ecto.Query
    case Repo.one(from r in queryable, where: field(r, ^unique_field) == ^unique_value) do
      nil ->
        {:ok, record} = create_fn.()
        IO.puts("  Created: #{inspect(unique_value)}")
        record
      existing ->
        IO.puts("  Exists: #{inspect(unique_value)}")
        existing
    end
  end
end

# --- 1. User ---
IO.puts("\n--- User ---")
user = case Accounts.get_user_by_email("qa@example.com") do
  nil ->
    {:ok, user} = Accounts.register_user(%{email: "qa@example.com"})
    {:ok, {user, _}} = Accounts.update_user_password(user, %{password: "hello world!"})
    IO.puts("  Created: qa@example.com")
    user
  user ->
    IO.puts("  Exists: qa@example.com")
    user
end

scope = MyApp.Users.Scope.for_user(user)

# --- 2. More entities using context functions ---
IO.puts("\n--- Account ---")
account = QaSeed.find_or_create(MyApp.Accounts.Account, :name, "QA Account", fn ->
  Accounts.create_account(scope, %{name: "QA Account"})
end)

# ... more entities, each using context functions with scope

# --- Summary ---
IO.puts("""

==========================================
 QA Seed Data — Credentials
==========================================

Email:    qa@example.com
Password: hello world!
URL:      http://localhost:4000/users/log-in
""")
```

### Patterns

- **Idempotency**: check for existing records before inserting. Use context `get_by` functions or Ecto queries.
- **Use context functions**: call `Accounts.create_user(scope, attrs)` not `Repo.insert(%User{...})`. This ensures validations, associations, and side effects run.
- **Build Scope**: after creating the user, build a `Scope` to pass to all subsequent context calls.
- **Print credentials**: always print login info, URLs, and entity IDs at the end.
- **Multiple scripts**: split into separate files for different scenarios (base entities vs. specific test flows). Each is independently runnable.

## Smoke test scripts

For hitting every route and checking for 500s:

```bash
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${APP_URL:-http://localhost:4000}"
COOKIE_JAR="/tmp/app_qa_cookies.txt"
FAIL=0

smoke() {
  local method="${1:-GET}"
  local path="$2"
  local expected="${3:-200}"

  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X "$method" -b "$COOKIE_JAR" "$BASE_URL$path")

  if [ "$HTTP_CODE" = "$expected" ]; then
    echo "  PASS $method $path → $HTTP_CODE"
  else
    echo "  FAIL $method $path → $HTTP_CODE (expected $expected)"
    FAIL=1
  fi
}

# Public routes
smoke GET "/"
smoke GET "/users/log-in"
smoke GET "/users/register"

# Authenticated routes (run authenticated_curl.sh first)
smoke GET "/dashboard"
smoke GET "/settings"

# API routes
smoke POST "/api/endpoint" 401  # expect unauthorized without key

exit $FAIL
```

### Tips

- Run `authenticated_curl.sh` first to populate the cookie jar
- Accept 302 as valid for auth-protected routes when not logged in
- Check for 500s specifically — a 404 or 302 might be expected
- Use `mix phx.routes` output to build the route list

## Browser-based QA tools

Two browser tools cover the full QA spectrum for Phoenix apps. Use **`web`** for all standard Phoenix LiveView interactions. Use **Vibium** when you need capabilities beyond what `web` provides.

### `web` — Phoenix LiveView QA (primary tool)

Go-based headless browser CLI by Chris McCord. Uses Firefox + geckodriver, converts pages to markdown, has native LiveView support. Self-contained binary — auto-downloads Firefox to `~/.web-firefox/` on first run (~102MB).

**All options:**
```
web <url> [options]

  --raw                      Output raw HTML instead of markdown
  --truncate-after <number>  Truncate output after N chars (default: 100000)
  --screenshot <filepath>    Save full-page screenshot as PNG
  --form <id>                Target form by its HTML id attribute
  --input <name>             Form input name attribute (pair with --value)
  --value <value>            Value for the preceding --input
  --after-submit <url>       Navigate to this URL after form submission
  --js <code>                Execute JavaScript after page loads
  --profile <name>           Named session profile for cookie/state persistence (default: "default")
```

#### QA workflow: authenticate first, then test

The `--profile` flag persists a real Firefox profile (cookies, localStorage, sessionStorage) to `~/.web-firefox/profiles/<name>/`. Once you log in with a profile, all subsequent calls with that profile name are already authenticated.

**Step 1: Log in once at the start of the QA session**
```bash
web http://localhost:4000/users/log-in \
    --profile "qa" \
    --form "login_form_password" \
    --input "user[email]" --value "qa@example.com" \
    --input "user[password]" --value "hello world!" \
    --truncate-after 100
```
`phx.gen.auth` generates predictable form IDs: `login_form_password` for password login, `login_form_magic` for passwordless/magic-link login, `registration_form` for registration. The password form uses `phx-trigger-action` — the `web` tool handles this automatically via Enter key submission.

**Step 2: Browse authenticated pages freely**
```bash
# Read page content as markdown
web http://localhost:4000/dashboard --profile "qa"

# Take a screenshot for evidence
web http://localhost:4000/settings --profile "qa" --screenshot settings.png

# Get raw HTML when you need to inspect DOM structure
web http://localhost:4000/items --profile "qa" --raw
```

**Single-command login + navigate (for one-off checks):**
```bash
web http://localhost:4000/users/log-in \
    --profile "qa" \
    --form "login_form_password" \
    --input "user[email]" --value "qa@example.com" \
    --input "user[password]" --value "hello world!" \
    --after-submit "http://localhost:4000/dashboard"
```
`--after-submit` does a hard navigation after login, so the output is the protected page's content.

#### Verifying page content

The tool outputs markdown by default. Check the stdout for expected content:
```bash
# Verify an element exists on the page
web http://localhost:4000/dashboard --profile "qa" --truncate-after 5000
# → look for expected headings, text, links in the markdown output
```

Use `--js` with `console.log()` for programmatic assertions — console output appears in a `CONSOLE OUTPUT:` section of stdout:
```bash
# Check specific element content
web http://localhost:4000/dashboard --profile "qa" \
    --js "console.log('TITLE:', document.querySelector('h1')?.textContent)"
# → stdout includes: [LOG] TITLE: Dashboard

# Count items in a list
web http://localhost:4000/items --profile "qa" \
    --js "console.log('COUNT:', document.querySelectorAll('.item').length)"
# → stdout includes: [LOG] COUNT: 5

# Check for error states
web http://localhost:4000/form --profile "qa" \
    --js "console.log('ERRORS:', document.querySelectorAll('.invalid-feedback').length)"
```

Console messages are tagged by level: `[LOG]`, `[WARNING]`, `[ERROR]`. Browser-level JS errors and network errors also appear automatically.

#### Interacting with LiveView pages

The tool auto-detects LiveView pages (`[data-phx-session]` attribute) and handles them correctly:

- **Waits for connection**: blocks until `.phx-connected` appears before reading content
- **Form submission**: on LiveView forms, uses Enter key (not click) and waits for `phx:page-loading-stop`
- **Navigation tracking**: after `--js` execution, monitors Phoenix events for LiveView pages vs. `document.readyState` for regular pages

**Click buttons and interact via `--js`:**
```bash
# Click a phx-click button
web http://localhost:4000/items --profile "qa" \
    --js "document.querySelector('button[phx-click=\"delete\"]').click()"

# Submit a LiveView form
web http://localhost:4000/items/new --profile "qa" \
    --js "
        document.querySelector('#item_name').value = 'Test Item';
        document.querySelector('form').dispatchEvent(new Event('submit', {bubbles: true}));
    "

# Trigger a phx-change event (e.g., select dropdown)
web http://localhost:4000/items --profile "qa" \
    --js "
        const select = document.querySelector('select[name=\"filter\"]');
        select.value = 'active';
        select.dispatchEvent(new Event('change', {bubbles: true}));
    "
```

After JS-triggered navigation, the tool waits for the page to settle before capturing output, so the markdown reflects the post-interaction state.

#### Filling and submitting forms

Use `--form` + `--input`/`--value` pairs for structured form interaction (preferred over `--js` for simple forms):
```bash
# Create a new item via form
web http://localhost:4000/items/new --profile "qa" \
    --form "item_form" \
    --input "item[name]" --value "Test Item" \
    --input "item[description]" --value "Created by QA" \
    --after-submit "http://localhost:4000/items"
```

The `--form` flag targets a form by its HTML `id`. On LiveView pages, submission uses Enter key and waits for Phoenix navigation events. On regular pages, it clicks the submit button.

#### Screenshots as evidence

Always take screenshots for QA evidence, especially for visual checks:
```bash
web http://localhost:4000/dashboard --profile "qa" --screenshot qa_dashboard.png
web http://localhost:4000/items --profile "qa" --screenshot qa_items_list.png
```

#### Troubleshooting

- **Profile stale?** Delete `~/.web-firefox/profiles/<name>/` to start fresh
- **Geckodriver port conflict?** The tool uses port 4444 — make sure nothing else is bound there
- **Long pages?** Use `--truncate-after` to limit output size. Default is 100,000 chars
- **Need DOM structure?** Use `--raw` to get full HTML instead of markdown

### Vibium — full browser automation (when `web` isn't enough)

Vibium is a standalone browser automation binary by Jason Huggins (creator of Selenium). It drives a real Chrome instance via WebDriver BiDi. Single ~10MB binary, zero runtime dependencies.

**When to use**: Anything that "colors outside the lines" of standard LiveView — file uploads via native dialogs, drag-and-drop, multi-tab workflows, complex mouse interactions (hover chains, right-click menus), testing OAuth redirect flows through third-party providers, screenshot-based visual regression, or any interaction that requires a real browser viewport.

**Installation:**
```bash
# As MCP server for Claude Code
claude mcp add vibium -- npx -y vibium mcp

# As CLI
npm install -g vibium

# Python SDK
pip install vibium
```

**CLI usage:**
```bash
# Navigate and interact
vibium navigate http://localhost:4000
vibium click "button.submit"
vibium type "#email-input" "qa@example.com"
vibium screenshot -o page.png

# Wait for elements
vibium wait ".flash-message" --state visible --timeout 5000

# Multi-tab workflows (OAuth redirects, popups)
vibium tabs
vibium tab-switch 1
vibium click "#authorize-button"
vibium tab-switch 0

# Keyboard shortcuts, drag-and-drop
vibium keys "Control+a"
vibium hover ".draggable"
```

**Key commands:**

| Category | Commands |
|----------|----------|
| Navigate | `navigate <url>`, `url`, `title` |
| Read | `text [selector]`, `html`, `find <selector>`, `find-all <selector>`, `screenshot` |
| Interact | `click`, `type`, `hover`, `scroll`, `keys`, `select` |
| Wait | `wait <selector>` (`--state visible\|hidden\|attached`, `--timeout ms`) |
| Tabs | `tabs`, `tab-new`, `tab-switch`, `tab-close` |
| Eval | `eval "<js>"` |
| Daemon | `daemon start\|status\|stop` |

**Global flags:** `--headless`, `--json`, `--oneshot` (fresh browser per command, good for CI)

**Daemon mode** keeps the browser alive between commands for fast chaining. Use `--oneshot` in CI for clean isolation.

**MCP tools** (when running as MCP server): `browser_launch`, `browser_navigate`, `browser_click`, `browser_type`, `browser_screenshot`, `browser_find`, `browser_quit`.

### When to use which

| Scenario | Tool |
|----------|------|
| Navigate LiveView pages, verify content | `web` |
| Click phx-click buttons, submit phx-submit forms | `web` |
| Test live_patch / live_redirect navigation | `web` |
| Verify PubSub-pushed updates | `web` |
| Run JS against live DOM (phx-hook, JS commands) | `web` |
| File upload via native file picker | Vibium |
| Drag-and-drop (e.g. Sortable, reordering) | Vibium |
| Multi-tab flows (OAuth popups, third-party redirects) | Vibium |
| Screenshot capture / visual regression | Vibium |
| Complex hover/right-click/context menus | Vibium |
| Testing across browser viewport sizes | Vibium |
| Keyboard shortcut testing | Vibium |
