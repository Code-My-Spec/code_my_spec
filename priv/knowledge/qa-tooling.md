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

## Browser-based QA with Vibium

Vibium is a standalone browser automation CLI by Jason Huggins (creator of Selenium). It drives a real Chrome instance via WebDriver BiDi. Single ~10MB binary, zero runtime dependencies. Covers the full QA spectrum for Phoenix apps — navigating pages, verifying content, filling forms, clicking buttons, file uploads, multi-tab flows, screenshots, and more.

**Installation:**
```bash
# As CLI
npm install -g vibium
```

### Core workflow

Every browser automation follows this pattern:

1. **Navigate**: `vibium go <url>`
2. **Map**: `vibium map` (get element refs like `@e1`, `@e2`)
3. **Interact**: Use refs to click, fill, select — e.g. `vibium click @e1`
4. **Re-map**: After navigation or DOM changes, get fresh refs with `vibium map`

```bash
vibium go http://localhost:4000 && vibium map && vibium click @e1 && vibium diff map
```

### QA workflow: authenticate first, then test

Use `vibium storage-state` to persist auth across commands. Once you log in and save state, restore it in later sessions to skip login.

**Step 1: Log in once at the start of the QA session**
```bash
vibium go http://localhost:4000/users/log-in
vibium map
# Identify the email field, password field, and submit button from map output
vibium fill @e1 "qa@example.com"
vibium fill @e2 "hello world!"
vibium click @e3
vibium wait-for-url "/dashboard"
vibium storage-state -o qa_auth.json
```

`phx.gen.auth` generates predictable form IDs: `login_form_password` for password login, `login_form_magic` for passwordless/magic-link login, `registration_form` for registration.

**Step 2: Restore auth and browse freely**
```bash
# Restore saved session
vibium restore-storage qa_auth.json

# Read page content as text
vibium go http://localhost:4000/dashboard && vibium text

# Take a screenshot for evidence
vibium go http://localhost:4000/settings && vibium screenshot -o settings.png

# Get raw HTML when you need to inspect DOM structure
vibium go http://localhost:4000/items && vibium html
```

### Verifying page content

```bash
# Read all page text
vibium go http://localhost:4000/dashboard && vibium text

# Read text within a specific element
vibium text "h1"
vibium text ".flash-message"

# Count elements
vibium count ".item"

# Check element state
vibium is-visible ".modal"
vibium is-enabled "button[type=submit]"
vibium value "input[name=email]"
vibium attr "a" "href"

# Programmatic checks via JS
vibium eval 'document.querySelector("h1")?.textContent'
vibium eval 'document.querySelectorAll(".item").length'
```

### Interacting with LiveView pages

LiveView pages work like any other page with Vibium. After interactions that trigger server-side changes, use explicit waits:

```bash
# Click a phx-click button
vibium click "button[phx-click='delete']"
vibium wait-for-text "deleted"

# Submit a LiveView form
vibium fill "#item_name" "Test Item"
vibium click "button[type=submit]"
vibium wait-for-url "/items"

# Trigger a phx-change event (e.g., select dropdown)
vibium select "select[name='filter']" "active"

# Wait for LiveView to reconnect after navigation
vibium wait "[data-phx-session]" --state attached
```

### Filling and submitting forms

Use `vibium map` to discover form fields, then `vibium fill` to set values:

```bash
# Create a new item via form
vibium go http://localhost:4000/items/new
vibium map --selector "form"
# Map output shows: @e1 [input] name="item[name]", @e2 [textarea] name="item[description]", @e3 [button] "Save"
vibium fill @e1 "Test Item"
vibium fill @e2 "Created by QA"
vibium click @e3
vibium wait-for-url "/items"
```

Use `vibium fill` to replace a field's value (clears first), `vibium type` to append to existing value.

### Semantic element discovery

Find elements without CSS selectors:
```bash
vibium find --text "Sign In"            # by visible text
vibium find --label "Email"             # by form label
vibium find --placeholder "Search..."   # by placeholder
vibium find --testid "submit-btn"       # by data-testid
vibium find --role "button"             # by ARIA role
vibium find --alt "Logo"                # by alt attribute
vibium click @e1                        # click whatever was found
```

### Screenshots as evidence

Always take screenshots for QA evidence, especially for visual checks:
```bash
vibium go http://localhost:4000/dashboard && vibium screenshot -o qa_dashboard.png
vibium go http://localhost:4000/items && vibium screenshot -o qa_items_list.png

# Annotated screenshot (labels interactive elements)
vibium screenshot -o annotated.png --annotate

# Full-page screenshot
vibium screenshot -o full.png --full-page
```

### Advanced interactions

```bash
# File upload
vibium upload "input[type=file]" ./document.pdf

# Multi-tab workflows (OAuth redirects, popups)
vibium tab-new http://external-provider.com/authorize
vibium click "#authorize-button"
vibium tab-switch 0

# Drag-and-drop
vibium drag ".draggable" ".drop-target"

# Keyboard shortcuts
vibium keys "Control+a"
vibium press "Enter" "#search-input"

# Hover interactions
vibium hover ".menu-trigger"

# Viewport testing
vibium set-viewport 375 812  # iPhone viewport
vibium screenshot -o mobile.png
```

### Key commands

| Category | Commands |
|----------|----------|
| Navigate | `go <url>`, `back`, `forward`, `reload`, `url`, `title` |
| Discover | `map`, `map --selector`, `diff map`, `find`, `find-all`, `count` |
| Read | `text [selector]`, `html`, `screenshot`, `a11y-tree`, `eval` |
| Interact | `click`, `dblclick`, `fill`, `type`, `press`, `hover`, `scroll`, `keys`, `select`, `check`, `uncheck` |
| Forms | `fill` (clear+type), `type` (append), `select`, `upload`, `value` |
| State | `is-visible`, `is-enabled`, `is-checked`, `attr`, `value` |
| Wait | `wait`, `wait-for-url`, `wait-for-text`, `wait-for-load`, `wait-for-fn` |
| Tabs | `tabs`, `tab-new`, `tab-switch`, `tab-close` |
| Auth | `storage-state -o`, `restore-storage`, `cookies`, `cookies set`, `cookies clear` |
| Capture | `screenshot -o` (`--full-page`, `--annotate`), `pdf -o` |
| Session | `daemon start\|status\|stop`, `quit` |

**Global flags:** `--headless`, `--json`, `--oneshot` (fresh browser per command, good for CI)

**Daemon mode** keeps the browser alive between commands for fast chaining. Use `--oneshot` in CI for clean isolation.

### Troubleshooting

- **Stale refs?** Always re-map after navigation or DOM changes — refs are invalidated on page change
- **Element not actionable?** All interaction commands auto-wait, but use explicit `vibium wait` for dynamically loaded content
- **Need full CLI reference?** See `priv/knowledge/qa-tooling/vibium_reference.md`
