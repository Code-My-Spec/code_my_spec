# Cloudflare DNS and Tunnel Setup for Web App Deployment

Reference guide for deploying web apps with Cloudflare DNS, Cloudflare Tunnels, and Caddy as the origin reverse proxy. Covers multi-environment DNS routing, tunnel-based dev access, SSL/TLS configuration, and the Cloudflare API.

## Context

This document is grounded in the fuellytics.app deployment architecture:

- **Origin server**: Hetzner VPS running Docker Compose (Caddy + Elixir app + Postgres)
- **DNS provider**: Cloudflare (fuellytics.app zone)
- **Environments**:
  - `fuellytics.app` — production (Cloudflare proxied A record to Hetzner IP)
  - `uat.fuellytics.app` — UAT (Cloudflare proxied A record, same Hetzner IP, different Docker Compose stack)
  - `dev.fuellytics.app` — development (Cloudflare CNAME to tunnel, routes to localhost:4090)
- **Origin TLS**: Caddy handles HTTPS on the origin; Cloudflare proxies terminate public TLS in Full (strict) mode
- **Dev tunnels**: An Elixir GenServer manages the `cloudflared` process using `Port.open/2`

---

## 1. DNS Management

### Record Types

**A record** — Maps a hostname to an IPv4 address. Use for apex (`@`) and subdomains pointing to your server IP.

```
Type: A
Name: @           (or fuellytics.app)
Content: 46.225.105.88
Proxied: true
TTL: Auto
```

**AAAA record** — Same as A but for IPv6. Add alongside A records if your server has an IPv6 address.

**CNAME record** — Maps a hostname to another hostname. Cannot be used at the zone apex (`@`) in standard DNS, but Cloudflare supports it via CNAME flattening (see below).

```
Type: CNAME
Name: uat
Content: fuellytics.app
Proxied: true
TTL: Auto
```

### Proxied vs DNS-Only

Every A, AAAA, and CNAME record in Cloudflare has a proxy status:

| Mode | Icon | Effect |
|------|------|--------|
| Proxied | Orange cloud | Traffic routes through Cloudflare's edge network. Origin IP is hidden. DDoS protection, WAF, caching, and analytics apply. |
| DNS-only | Gray cloud | Cloudflare returns the raw IP in DNS responses. No proxying, no Cloudflare features. Origin IP is exposed. |

For Cloudflare Tunnels, the CNAME record that routes to `<uuid>.cfargotunnel.com` **must be proxied** — Cloudflare needs to intercept requests in order to route them into the tunnel.

For records pointing directly to your server (prod, UAT), proxied mode is strongly recommended:
- Hides your origin IP from the public internet
- Enables Full (strict) SSL/TLS
- Provides DDoS protection and analytics

Proxied records have a fixed 5-minute TTL (Cloudflare enforces `Auto`). DNS-only records accept custom TTLs (minimum 60s, or 30s for Enterprise).

### CNAME Flattening

Standard DNS does not permit CNAME records at the zone apex (`example.com` itself) — only subdomains. Cloudflare solves this with **CNAME flattening**: when the zone apex has a CNAME, Cloudflare recursively resolves the chain and returns the final A record IP, making the apex behave like a proper A record to clients while still allowing CNAME-style configuration on your end.

CNAME flattening is automatic in Cloudflare for all plans when the record name is `@`.

In practice, for `fuellytics.app` pointing to a fixed IP (Hetzner), use a direct A record — CNAME flattening matters more when the apex needs to point to a CNAME target (like a load balancer hostname).

### Multi-Environment DNS Setup

For three environments — prod at apex, UAT at subdomain, dev via tunnel — the DNS records look like:

```
# Production — apex A record, proxied
Type: A,  Name: @,   Content: 46.225.105.88, Proxied: true

# UAT — subdomain A record pointing to same server, proxied
Type: A,  Name: uat, Content: 46.225.105.88, Proxied: true

# Dev — CNAME pointing to Cloudflare Tunnel, proxied (must be proxied)
Type: CNAME, Name: dev, Content: <tunnel-uuid>.cfargotunnel.com, Proxied: true
```

Caddy on the origin server uses virtual hosting to route requests by `Host` header:
- `fuellytics.app` → prod container (port 4000)
- `uat.fuellytics.app` → UAT container (port 4001)
- `dev.fuellytics.app` — handled by the tunnel, not by the origin server at all

---

## 2. Cloudflare Tunnels

### What They Are

Cloudflare Tunnels (formerly Argo Tunnel) let you expose a local service to the internet without opening inbound firewall ports. Instead of the internet connecting to your server, your server connects *out* to Cloudflare's edge network, and Cloudflare routes matching traffic back through that connection.

Key properties:
- **Outbound-only connections**: `cloudflared` opens 4 persistent QUIC (or HTTP/2) connections to Cloudflare data centers. No inbound rules needed.
- **No public IP exposure**: The origin IP never appears in DNS for tunnel-routed hostnames.
- **mTLS between cloudflared and Cloudflare edge**: Mutual TLS authentication — both sides validate certificates.
- **Zero Trust capable**: Tunnels integrate with Cloudflare Access for identity-aware access control (not required for simple dev tunnels).

### Architecture

```
Browser → Cloudflare Edge
              ↓  (tunneled, encrypted)
          cloudflared daemon (on dev machine / server)
              ↓  (local HTTP)
          localhost:4090 (Phoenix dev server)
```

The DNS record `dev.fuellytics.app CNAME <uuid>.cfargotunnel.com` tells Cloudflare to route requests for `dev.fuellytics.app` through the tunnel identified by that UUID.

### Tunnel Types

**Locally-managed tunnels** — Created via `cloudflared tunnel create <name>`. Configuration (YAML) and credentials (JSON) are stored on the machine running cloudflared. Suits automated/programmatic setups (like the Elixir GenServer approach in fuellytics).

**Remotely-managed tunnels** — Created in the Cloudflare Zero Trust dashboard or via API. Configuration is stored in Cloudflare. Connector runs with just a `TUNNEL_TOKEN` environment variable. Suits Docker and Kubernetes deployments.

The fuellytics approach uses locally-managed tunnels because:
- Credentials can be stored in env vars and reconstructed at runtime without user interaction
- The Elixir GenServer generates the config YAML and credentials JSON programmatically
- No Cloudflare dashboard interaction needed after the tunnel is initially provisioned

### Installing cloudflared

```bash
# macOS
brew install cloudflared

# Linux (Debian/Ubuntu)
wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
sudo dpkg -i cloudflared-linux-amd64.deb

# Linux (binary)
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
  -o /usr/local/bin/cloudflared && chmod +x /usr/local/bin/cloudflared
```

Official downloads: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/downloads/

### Creating a Named Tunnel (One-Time Setup)

```bash
# Step 1: Authenticate cloudflared with your Cloudflare account
# Opens browser, downloads cert.pem to ~/.cloudflared/
cloudflared tunnel login

# Step 2: Create a named tunnel
# Generates ~/.cloudflared/<UUID>.json (credentials file)
cloudflared tunnel create dev-fuellytics

# Note the UUID output — you need it for config and DNS
# Example: 82c13f72-7b13-4d8c-b702-bfabbf8efacd

# Step 3: Create the DNS CNAME record pointing to the tunnel
# Requires cert.pem from the login step
cloudflared tunnel route dns dev-fuellytics dev.fuellytics.app

# Step 4: Verify
cloudflared tunnel list
cloudflared tunnel info dev-fuellytics
```

The `tunnel route dns` command creates the CNAME record `dev.fuellytics.app → <UUID>.cfargotunnel.com` in Cloudflare DNS automatically using your cert.pem credentials.

### Credentials File Format

When you run `cloudflared tunnel create`, it generates a JSON credentials file at `~/.cloudflared/<UUID>.json`:

```json
{
  "AccountTag": "6477547f586ec90db2c2a0081dcd98bd",
  "TunnelSecret": "<base64-encoded-secret>",
  "TunnelID": "82c13f72-7b13-4d8c-b702-bfabbf8efacd",
  "Endpoint": ""
}
```

- **AccountTag**: Your Cloudflare account ID (from dashboard URL or API)
- **TunnelSecret**: Random secret generated at tunnel creation; cannot be retrieved after creation (only rotated)
- **TunnelID**: UUID assigned to the tunnel
- **Endpoint**: Usually empty; can specify a specific Cloudflare colo

This file should be treated as a secret. In the fuellytics project, `TunnelSecret` is stored in `CLOUDFLARE_TUNNEL_SECRET` env var and the credentials JSON is written to disk at runtime by the GenServer.

### config.yml Structure

The cloudflared configuration file maps hostnames to local services via ingress rules:

```yaml
tunnel: 82c13f72-7b13-4d8c-b702-bfabbf8efacd
credentials-file: /home/user/.cloudflared/credentials.json

ingress:
  # Route dev.fuellytics.app to local Phoenix server
  - hostname: dev.fuellytics.app
    service: http://127.0.0.1:4090

  # Optional: additional services on the same tunnel
  - hostname: admin.dev.fuellytics.app
    service: http://127.0.0.1:4090/admin

  # Catch-all rule — required, must be last
  - service: http_status:404
```

Key points:
- The `tunnel` field accepts either a UUID or a name.
- `credentials-file` is the path to the JSON credentials file.
- Ingress rules are evaluated top-to-bottom; first match wins.
- The catch-all `- service: http_status:404` is mandatory — cloudflared will refuse to start without it.
- cloudflared looks for config at `~/.cloudflared/config.yml` by default. Override with `--config <path>`.

### Service Types

| Service value | Purpose |
|--------------|---------|
| `http://...` | Plain HTTP origin |
| `https://...` | HTTPS origin (with optional `originServerName` or `noTLSVerify`) |
| `http_status:404` | Return HTTP status code directly |
| `hello_world` | Built-in test server |
| `ssh://...` | SSH proxy |
| `rdp://...` | RDP proxy |

### Running the Tunnel

```bash
# Run using default config at ~/.cloudflared/config.yml
cloudflared tunnel --no-autoupdate run

# Run a specific tunnel by name or UUID (config must reference it)
cloudflared tunnel --no-autoupdate run dev-fuellytics

# Run with a custom config path
cloudflared tunnel --config /path/to/config.yml --no-autoupdate run
```

`--no-autoupdate` prevents cloudflared from updating itself, which is desirable in programmatically-managed setups.

### Useful cloudflared Commands

```bash
# List all tunnels in the account
cloudflared tunnel list

# Show info about a specific tunnel
cloudflared tunnel info <name-or-uuid>

# Delete a tunnel (must be stopped first)
cloudflared tunnel delete <name-or-uuid>

# Rotate tunnel secret (invalidates old credentials)
cloudflared tunnel rotate-secret <name-or-uuid>

# Clean up unused DNS records
cloudflared tunnel cleanup <name-or-uuid>
```

### Elixir GenServer Pattern

The fuellytics project manages `cloudflared` as an Erlang port process. The GenServer:

1. Reads config from `Application.get_env/3`
2. Writes `~/.cloudflared/config.yml` with the tunnel UUID, credentials path, and ingress rules
3. Writes `tmp/cloudflared/credentials.json` from env var values
4. Opens a port with `Port.open({:spawn_executable, cloudflared_path}, [:binary, :exit_status, ...])`
5. Logs stdout/stderr output via `handle_info({port, {:data, _}})`
6. Stops the OTP supervisor tree if the process exits unexpectedly via `handle_info({port, {:exit_status, _}})`

```elixir
# Config shape (dev.exs)
config :myapp, :cloudflare_tunnel,
  enabled: true,
  hostname: "dev.myapp.com",
  tunnel_id: "82c13f72-...",
  account_tag: "6477547f...",
  tunnel_secret: "",   # populated from CLOUDFLARE_TUNNEL_SECRET env in runtime.exs
  origin_url: "http://127.0.0.1:4000"

# runtime.exs — merge secret into existing config
tunnel_config = Application.get_env(:myapp, :cloudflare_tunnel, [])
if tunnel_config[:enabled] do
  config :myapp, :cloudflare_tunnel,
    Keyword.put(tunnel_config, :tunnel_secret, env!("CLOUDFLARE_TUNNEL_SECRET", :string, ""))
end
```

Key behaviors of the GenServer:
- Return `:ignore` from `init/1` if cloudflared is not in PATH or secret is empty — prevents crash in environments where tunnel is not configured.
- Close the port in `terminate/2` with a `catch :error, :badarg` guard for the case where the port is already dead.
- The GenServer should be started as a child of your dev supervision tree only, not in production.

For extraction into a shared library (the planned next step), the GenServer would accept all parameters explicitly and generate paths under a configurable base directory rather than hardcoding `~/.cloudflared`.

---

## 3. SSL/TLS Configuration

### Cloudflare Encryption Modes

Set in the Cloudflare dashboard under SSL/TLS > Overview, or via API.

| Mode | Edge-to-Origin Encryption | Certificate Validation | Use With |
|------|--------------------------|----------------------|----------|
| Off | None | — | Never (sends HTTP) |
| Flexible | None | — | Origin without TLS (not recommended) |
| Full | Yes | Not validated (self-signed OK) | Any HTTPS origin |
| Full (strict) | Yes | Validated (CA-signed or Cloudflare Origin CA) | Caddy with valid cert |

**Recommendation: Full (strict).** This ensures:
- Client ↔ Cloudflare edge: public CA certificate (Cloudflare issues an edge certificate automatically)
- Cloudflare edge ↔ Origin (Caddy): validated HTTPS, origin must present a certificate trusted by Cloudflare

### Caddy with Cloudflare: TLS Options

**Option A: Let Caddy get its own Let's Encrypt cert (simplest)**

Caddy requests and renews certificates from Let's Encrypt using the ACME HTTP-01 or TLS-ALPN-01 challenge. With Cloudflare proxied DNS, HTTP-01 works because Cloudflare passes `/.well-known/acme-challenge` through by default.

```
fuellytics.app {
    reverse_proxy app:4000
}
```

Caddy handles everything automatically. This works well with Full (strict) mode because Caddy's Let's Encrypt cert is signed by a public CA that Cloudflare trusts.

**Option B: Cloudflare Origin CA certificate (15-year validity)**

For servers that should only accept connections from Cloudflare (not direct), use a Cloudflare Origin CA certificate. These are valid for up to 15 years and are trusted by Cloudflare but not by public browsers — appropriate when Cloudflare is always in front of your origin.

To issue:
1. Cloudflare dashboard > SSL/TLS > Origin Server > Create Certificate
2. Let Cloudflare generate the private key and CSR (RSA, 15-year validity)
3. Save the certificate as `origin-cert.pem` and private key as `origin-key.pem` on the server
4. Set SSL/TLS mode to Full (strict)

Caddyfile configuration:
```
fuellytics.app {
    tls /etc/ssl/cloudflare/origin-cert.pem /etc/ssl/cloudflare/origin-key.pem
    reverse_proxy app:4000
}
```

**Option C: tls internal (for non-public origins behind tunnel)**

For dev environments accessed only through Cloudflare Tunnel, Caddy's self-signed "internal" certificate works — the tunnel terminates at Cloudflare edge and never exposes the internal cert to public clients.

```
dev.fuellytics.app {
    tls internal
    reverse_proxy app:4000
}
```

However, if the dev server runs locally without Caddy (just `mix phx.server` on port 4090), the tunnel routes directly to HTTP — no TLS on origin needed:
```yaml
# In cloudflared config.yml
ingress:
  - hostname: dev.fuellytics.app
    service: http://127.0.0.1:4090
```

### Caddy and trusted_proxies

When Caddy sits behind Cloudflare, all incoming connections appear to come from Cloudflare's IP ranges, not the real client IP. The real client IP is passed via `CF-Connecting-IP` and `X-Forwarded-For` headers.

Configure Caddy to trust Cloudflare's IP ranges globally:

```
{
    servers {
        trusted_proxies static \
            103.21.244.0/22 \
            103.22.200.0/22 \
            103.31.4.0/22 \
            104.16.0.0/13 \
            104.24.0.0/14 \
            108.162.192.0/18 \
            131.0.72.0/22 \
            141.101.64.0/18 \
            162.158.0.0/15 \
            172.64.0.0/13 \
            173.245.48.0/20 \
            188.114.96.0/20 \
            190.93.240.0/20 \
            197.234.240.0/22 \
            198.41.128.0/17 \
            2400:cb00::/32 \
            2606:4700::/32 \
            2803:f800::/32 \
            2405:b500::/32 \
            2405:8100::/32 \
            2a06:98c0::/29 \
            2c0f:f248::/32
        client_ip_headers CF-Connecting-IP X-Forwarded-For
        trusted_proxies_strict
    }
}

fuellytics.app {
    reverse_proxy app:4000
}
```

The `trusted_proxies_strict` option prevents clients from spoofing the `X-Forwarded-For` header (Cloudflare appends to the right; `strict` mode takes the right-most value from trusted proxies).

The current Cloudflare IP range files are at:
- IPv4: https://www.cloudflare.com/ips-v4
- IPv6: https://www.cloudflare.com/ips-v6

These change infrequently; Cloudflare publishes new ranges before putting them in production.

**Alternative: caddy-cloudflare-ip module**

A community module that auto-fetches and refreshes Cloudflare's IP ranges:
```
{
    servers {
        trusted_proxies cloudflare {
            interval 12h
            timeout 15s
        }
    }
}
```
Requires a custom Caddy build with the module included. See: https://github.com/WeidiDeng/caddy-cloudflare-ip

---

## 4. Multi-Environment DNS Routing

### DNS Records Summary

For the fuellytics.app setup:

| Hostname | Record Type | Content | Proxied | Target |
|----------|------------|---------|---------|--------|
| `fuellytics.app` | A | `46.225.105.88` | Yes | Caddy on Hetzner → prod Docker container |
| `uat.fuellytics.app` | A | `46.225.105.88` | Yes | Caddy on Hetzner → UAT Docker container |
| `dev.fuellytics.app` | CNAME | `<uuid>.cfargotunnel.com` | Yes | Cloudflare Tunnel → localhost:4090 |

### Caddy Routing for Prod and UAT

Since prod and UAT share the same Hetzner IP and the same Caddy instance, Caddy routes by `Host` header:

```
fuellytics.app {
    reverse_proxy app:4000
}

uat.fuellytics.app {
    reverse_proxy uat-app:4001
}
```

The corresponding `docker-compose.yml` runs two separate app services on different ports, or two separate compose projects with different `PHX_HOST` environment variables.

### Dev Tunnel: No Caddy Involvement

The dev environment (`dev.fuellytics.app`) routes entirely through the Cloudflare Tunnel to the developer's local machine. Caddy on the Hetzner server never sees this traffic. The Phoenix dev server at `localhost:4090` handles requests directly.

The Phoenix endpoint must be configured to know its public hostname:
```elixir
# dev.exs
config :myapp, MyAppWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4090],
  url: [host: "dev.fuellytics.app", scheme: "https", port: 443],
  check_origin: false   # because real origin is cloudflare edge
```

`check_origin: false` is needed because WebSocket upgrade requests arrive with an `Origin: https://dev.fuellytics.app` header, but the actual connection comes from Cloudflare's IP — Phoenix's origin check would otherwise reject it.

---

## 5. Cloudflare API

### Authentication

Create an API token at: Cloudflare Dashboard > My Profile > API Tokens > Create Token.

Recommended template: **Edit zone DNS** (grants `Zone:DNS:Edit` + `Zone:Zone:Read`).

For more operations (e.g., managing tunnels), add:
- `Account:Cloudflare Tunnel:Edit`

API tokens are scoped and revocable — prefer them over the legacy Global API Key.

```bash
# Test your token
curl -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
  -H "Authorization: Bearer $CF_API_TOKEN"
```

### Get Zone ID

```bash
# List zones, filter by name
curl -s "https://api.cloudflare.com/client/v4/zones?name=fuellytics.app" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" \
  | jq -r '.result[0].id'
```

Zone ID is also visible in the Cloudflare dashboard: Websites > select domain > Overview > API section (right sidebar).

Store the zone ID as `CF_ZONE_ID` for subsequent API calls.

### List DNS Records

```bash
curl -s "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  | jq '.result[] | {name, type, content, proxied}'
```

Filter by type or name:
```bash
# All A records
curl -s "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?type=A" \
  -H "Authorization: Bearer $CF_API_TOKEN"

# Specific record by name
curl -s "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?name=uat.fuellytics.app" \
  -H "Authorization: Bearer $CF_API_TOKEN"
```

### Create a DNS Record

```bash
# Create an A record
curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "A",
    "name": "uat",
    "content": "46.225.105.88",
    "ttl": 1,
    "proxied": true,
    "comment": "UAT environment"
  }'

# Create a CNAME record for a tunnel
curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "CNAME",
    "name": "dev",
    "content": "82c13f72-7b13-4d8c-b702-bfabbf8efacd.cfargotunnel.com",
    "ttl": 1,
    "proxied": true,
    "comment": "Dev tunnel"
  }'
```

`ttl: 1` means "automatic" (Cloudflare-managed TTL). For proxied records, TTL is always automatic regardless of this value.

### Update a DNS Record

```bash
# First get the record ID
RECORD_ID=$(curl -s "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?name=uat.fuellytics.app" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  | jq -r '.result[0].id')

# Update with PATCH (partial update — only provided fields are changed)
curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$RECORD_ID" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"content": "46.225.105.99"}'

# Full replace with PUT
curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$RECORD_ID" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "A",
    "name": "uat",
    "content": "46.225.105.99",
    "ttl": 1,
    "proxied": true
  }'
```

### Delete a DNS Record

```bash
curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$RECORD_ID" \
  -H "Authorization: Bearer $CF_API_TOKEN"
```

### API Response Shape

All Cloudflare API responses follow this envelope:

```json
{
  "success": true,
  "errors": [],
  "messages": [],
  "result": { ... }
}
```

Always check `success` before using `result`. On error, `errors` contains objects with `code` and `message` fields.

---

## 6. Integration Patterns

### Full Environment Config Example

For a production deploy + dev tunnel setup on the same domain:

**DNS records (via API or dashboard):**
```
A     @           46.225.105.88    proxied
A     uat         46.225.105.88    proxied
CNAME dev         <uuid>.cfargotunnel.com  proxied
```

**Caddyfile on Hetzner:**
```
{
    servers {
        trusted_proxies static 103.21.244.0/22 ... (Cloudflare ranges)
        client_ip_headers CF-Connecting-IP X-Forwarded-For
        trusted_proxies_strict
    }
}

fuellytics.app {
    reverse_proxy app:4000
}

uat.fuellytics.app {
    reverse_proxy uat-app:4001
}
```

**Cloudflare dashboard SSL/TLS setting:** Full (strict)

**Dev machine: cloudflared config.yml (written programmatically):**
```yaml
tunnel: 82c13f72-7b13-4d8c-b702-bfabbf8efacd
credentials-file: /Users/dev/project/tmp/cloudflared/credentials.json

ingress:
  - hostname: dev.fuellytics.app
    service: http://127.0.0.1:4090
  - service: http_status:404
```

**Dev machine: env vars in envs/dev.env:**
```
CLOUDFLARE_TUNNEL_SECRET=<base64-secret-from-credentials-json>
```

### Extracting the GenServer into a Shared Library

When extracting `CloudflareTunnel` GenServer into a reusable library (e.g., `mix new cloudflare_tunnel_ex --module CloudflareTunnel`), the key design decisions:

1. **Configurable paths**: Accept a `base_dir` option rather than hardcoding `~/.cloudflared`. This allows multiple tunnel processes in the same supervision tree without collisions.

2. **Config-file vs credentials-file location**: Write config to `<base_dir>/config.yml` and pass `--config <path>` to cloudflared, rather than relying on the `~/.cloudflared` default. This avoids conflicts when the library is used in multiple projects simultaneously.

3. **Restart strategy**: Decide whether the GenServer should restart the cloudflared process on exit (retry loop with exponential backoff) or propagate the failure up to the supervisor. The current fuellytics approach propagates the failure.

4. **Health check**: cloudflared exposes a metrics endpoint (`--metrics localhost:0`) with a `GET /ready` health check. The library could poll this to confirm the tunnel is live before reporting `:ok` from `init/1`.

5. **Named vs unnamed process**: Accept `name:` option to allow multiple tunnel processes side by side.

```elixir
# Library usage
children = [
  {CloudflareTunnel, [
    name: :dev_tunnel,
    hostname: "dev.myapp.com",
    tunnel_id: "...",
    account_tag: "...",
    tunnel_secret: System.fetch_env!("CLOUDFLARE_TUNNEL_SECRET"),
    origin_url: "http://127.0.0.1:4000",
    base_dir: Path.join(File.cwd!(), "tmp/cloudflared")
  ]}
]
```

---

## Reference Links

- [Cloudflare Tunnel overview](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/)
- [Create a locally-managed tunnel](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/create-local-tunnel/)
- [cloudflared configuration file reference](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/configuration-file/)
- [Routing tunnel traffic via DNS](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/routing-to-tunnel/dns/)
- [cloudflared tunnel run parameters](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/cloudflared-parameters/run-parameters/)
- [Cloudflare proxy status](https://developers.cloudflare.com/dns/proxy-status/)
- [Cloudflare SSL/TLS encryption modes](https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/)
- [Cloudflare Origin CA certificates](https://developers.cloudflare.com/ssl/origin-configuration/origin-ca/)
- [CNAME flattening](https://developers.cloudflare.com/dns/cname-flattening/)
- [Cloudflare DNS API - Create record](https://developers.cloudflare.com/api/resources/dns/subresources/records/methods/create/)
- [Cloudflare DNS API - List records](https://developers.cloudflare.com/api/resources/dns/subresources/records/methods/list/)
- [Cloudflare DNS API - Update record](https://developers.cloudflare.com/api/resources/dns/subresources/records/methods/edit/)
- [Find account and zone IDs](https://developers.cloudflare.com/fundamentals/account/find-account-and-zone-ids/)
- [Create API token](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/)
- [Cloudflare IP ranges](https://www.cloudflare.com/ips/)
- [Caddy reverse_proxy directive](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy)
- [Caddy global options (trusted_proxies)](https://caddyserver.com/docs/caddyfile/options)
- [cloudflared GitHub releases](https://github.com/cloudflare/cloudflared/releases)
