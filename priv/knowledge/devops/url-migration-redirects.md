# URL Migrations with a Phoenix Plug

Pattern for migrating URLs without losing SEO link equity. Lives as a small plug in the endpoint pipeline; backed by a compile-time map; runs before routing so the controllers never fire for legacy URLs.

---

## When to use this

Any time you change a URL but want external links, search results, and social shares to keep working:

- Moving content between routes (e.g., `/pages/foo` → `/blog/foo` after a content-type change)
- Renaming slugs without breaking inbound links
- Consolidating duplicate URLs to a canonical version
- Removing a route family that crawlers and bookmarks still hit

The pattern issues a **301 Moved Permanently**, which is what Google needs to transfer ~all link equity to the new URL.

---

## The plug

Single file. Compile-time map for the routes. Lives at `lib/<app>_web/plugs/legacy_redirects.ex`:

```elixir
defmodule MyAppWeb.Plugs.LegacyRedirects do
  @moduledoc """
  Issues 301 redirects for content that has moved between routes.
  """
  import Plug.Conn

  @redirects %{
    "/pages/old-slug" => "/blog/old-slug",
    "/pages/another-slug" => "/blog/another-slug"
    # add entries as you migrate URLs
  }

  def init(opts), do: opts

  def call(%Plug.Conn{method: "GET", request_path: path} = conn, _opts) do
    case Map.fetch(@redirects, path) do
      {:ok, target} ->
        conn
        |> put_resp_header("location", append_query(target, conn.query_string))
        |> send_resp(301, "")
        |> halt()

      :error ->
        conn
    end
  end

  def call(conn, _opts), do: conn

  defp append_query(path, ""), do: path
  defp append_query(path, query), do: path <> "?" <> query
end
```

### Wire into the endpoint (not the router)

```elixir
# lib/my_app_web/endpoint.ex
plug MyAppWeb.Plugs.TrailingSlashRedirect
plug MyAppWeb.Plugs.LegacyRedirects     # <-- here, before Plug.Session and the router
plug Plug.Session, @session_options
plug MyAppWeb.Router
```

The plug runs at the endpoint level so it short-circuits before sessions are loaded or the router matches. Cheap O(1) map lookup per request. Negligible overhead even at full traffic.

---

## Why these design choices

| Decision | Why |
|----------|-----|
| **Compile-time map** | Fast lookup, no DB or runtime config. For ≤ a few hundred redirects this is the simplest thing that works. |
| **301 (Moved Permanently)** vs 302 | 301 transfers link equity; 302 keeps it on the old URL. Use 301 unless the move is genuinely temporary. |
| **`send_resp` directly** vs `Phoenix.Controller.redirect/2` | One less layer. Matches the existing `TrailingSlashRedirect` plug style in this project. |
| **`halt()`** | Stops the plug pipeline immediately so the router never sees the request. |
| **Endpoint, not router** | Runs before any router-level concerns (CSRF, session). Cleaner separation: this is a transport-layer concern, not an application-layer one. |
| **Preserve query string** | Inbound links may carry UTM tags, anchors, or pagination params. Dropping them silently breaks analytics attribution. |
| **`GET` only** | Redirecting POST/PUT changes them to GET silently — usually wrong. Other methods fall through and 404 naturally. |

---

## Scaling beyond a few dozen entries

If your `@redirects` map grows past a few hundred or you need non-developers to edit it:

1. **Move to a database table** with `path` (unique), `redirect_to`, `type` (`:moved_permanently` | `:temporary_redirect`)
2. **Cache reads** — these are hot-path lookups. ETS-backed cache (`Cachex`) is the obvious choice
3. **Admin UI** for managing entries

A worked example of the database-backed version: <https://fullstackphoenix.com/tutorials/implement-permanent-redirects-with-phoenix-plug>

---

## Verifying

```bash
# Should return 301 with the right location header
curl -sI https://example.com/pages/old-slug | head -3
# HTTP/2 301
# date: ...
# location: /blog/old-slug

# Query string preservation
curl -sI 'https://example.com/pages/old-slug?utm_source=test' | grep -i location
# location: /blog/old-slug?utm_source=test
```

For SEO confirmation, check Google Search Console once the redirects have been crawled — the legacy URLs should disappear from the index over a few weeks as Google consolidates them onto the new canonical URLs.

---

## What this pattern is NOT for

- **Auth-related redirects** — those belong inside the router or controllers where you have session context
- **A/B-test routing** — use a router scope or LiveView mount logic
- **Internationalization** (e.g., `/foo` → `/en/foo`) — usually wants header-aware logic, not a static map
- **High-cardinality slug rewrites** (millions of legacy URLs) — go database-backed with a cache from the start
