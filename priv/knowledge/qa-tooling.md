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
