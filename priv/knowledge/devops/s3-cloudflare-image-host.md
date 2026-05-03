# Decoupled Image CDN: S3 + Cloudflare + Phoenix

Pattern for serving static content images (heroes, OG previews, blog assets) from S3 fronted by Cloudflare, so image updates don't require an app deploy.

---

## The problem this solves

When images live in `priv/static/images/` they're baked into the release. Every image update — a new blog hero, a regenerated OG card — requires a full app deploy. For a content-driven site that publishes regularly, this is a constant tax: you're rebuilding the BEAM release just to ship a PNG.

The pattern: serve all content images from an S3 bucket fronted by Cloudflare. The Phoenix helper builds URLs from a slug pattern with **no filesystem existence check** — meaning the running release doesn't need to know what images exist. New images go live with one `aws s3 sync` and a Cloudflare cache miss — seconds, not minutes. No deploy.

## Prerequisites

| Tool | Why | Install (macOS) |
|------|-----|------------------|
| AWS CLI | Bucket creation, `aws s3 sync` | `brew install awscli` + `aws sso login` |
| `cwebp` (libwebp) | Hero PNG → WebP conversion (~85% smaller) | `brew install webp` |
| `curl` + `python3` | Cloudflare API calls in `bin/purge-cdn` | preinstalled |
| Cloudflare API token | DNS edit + Page Rules edit + Cache Purge scopes | issued from CF dashboard, lives in `envs/dev.env` as `CLOUDFLARE_TOKEN` |

---

## Architecture

```
                ┌─────────────────────────────────┐
   Browser ───► │  Cloudflare edge (HTTPS)        │
                │  Page Rule: SSL = Flexible      │
                └────────────┬────────────────────┘
                             │ HTTP (port 80)
                             ▼
            ┌─────────────────────────────────────────────┐
            │  S3 Static Website Endpoint                  │
            │  images.codemyspec.com.s3-website-us-east-1  │
            │  .amazonaws.com                              │
            └────────────┬────────────────────────────────┘
                         │ Host: images.codemyspec.com
                         ▼
            ┌─────────────────────────────────────────────┐
            │  S3 bucket: images.codemyspec.com            │
            │  (bucket name MUST match the public host)    │
            └─────────────────────────────────────────────┘
```

---

## The "bucket name = public host" trick

S3 routes requests to buckets by the `Host` header (virtual-hosted style). When Cloudflare proxies `images.example.com` to S3, the `Host` header forwarded to S3 is `images.example.com`, not the CNAME target. S3 then looks for a bucket literally named `images.example.com`.

Three ways to reconcile this:

| Approach | Trade-off |
|----------|-----------|
| **Bucket name = host** (this pattern) | One bucket per host. Cleanest, works on free Cloudflare. |
| **Cloudflare Origin Rule** to rewrite `Host` header | Requires `Zone:Rulesets:Edit` on the API token. |
| **Cloudflare Worker** to rewrite `Host` | Most flexible, more moving parts. |

A bucket named with dots (e.g., `images.codemyspec.com`) cannot be used over HTTPS via the standard `*.s3.amazonaws.com` endpoint — the wildcard cert doesn't cover sub-subdomains. The S3 **website endpoint** (`*.s3-website-*.amazonaws.com`) is HTTP-only, which sidesteps the cert problem but requires Cloudflare to talk HTTP to the origin. That's what the `SSL: Flexible` Page Rule enables, scoped to just this hostname.

For public images on a public site, "Flexible" is fine: Cloudflare → S3 over HTTP, but the public-facing URL is HTTPS and the content is already public. Don't use this pattern for private/auth-gated assets.

---

## Setup

### 1. S3 bucket

```bash
BUCKET=images.example.com

aws s3 mb s3://$BUCKET --region us-east-1

# Lift the default public-access block
aws s3api put-public-access-block --bucket $BUCKET \
  --public-access-block-configuration \
    "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false"

# Public-read policy
aws s3api put-bucket-policy --bucket $BUCKET --policy "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [{
    \"Sid\": \"PublicRead\",
    \"Effect\": \"Allow\",
    \"Principal\": \"*\",
    \"Action\": \"s3:GetObject\",
    \"Resource\": \"arn:aws:s3:::$BUCKET/*\"
  }]
}"

# Static website hosting (path-based routing)
aws s3 website s3://$BUCKET/ --index-document index.html --error-document error.html
```

Bucket name must equal the public hostname. Region in the website endpoint URL has to match the bucket region.

### 2. Cloudflare DNS + Page Rule

Via API (token needs `Zone:DNS:Edit` and `Zone:Page Rules:Edit`):

```bash
ZONE=<zone_id>
HOST=images
TARGET=images.example.com.s3-website-us-east-1.amazonaws.com

# CNAME, proxied
curl -X POST -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records" \
  -d "{\"type\":\"CNAME\",\"name\":\"$HOST\",\"content\":\"$TARGET\",\"proxied\":true}"

# Page Rule: SSL = Flexible for this hostname only
curl -X POST -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE/pagerules" \
  -d '{
    "targets":[{"target":"url","constraint":{"operator":"matches","value":"images.example.com/*"}}],
    "actions":[{"id":"ssl","value":"flexible"}],
    "status":"active",
    "priority":1
  }'
```

The `proxied: true` (orange cloud) is required — that's what gives you the CDN, HTTPS termination, and DDoS protection.

### 3. Phoenix wiring

**`config/runtime.exs`** — add an env var with empty default so dev keeps using `priv/static/images`:

```elixir
config :code_my_spec, images_host: env!("IMAGES_HOST", :string, "")
```

**Helper module** — single source of URL truth:

```elixir
defmodule CodeMySpecWeb.ImageUrl do
  @moduledoc """
  Builds URLs for static content images. When IMAGES_HOST is set, serves
  from CDN. When unset, falls back to app-served /images/... so dev works.
  """

  def image_url(filename, base_url \\ nil) do
    case Application.get_env(:code_my_spec, :images_host) do
      host when is_binary(host) and host != "" ->
        "#{host}/#{filename}"

      _ ->
        if base_url, do: "#{base_url}/images/#{filename}", else: "/images/#{filename}"
    end
  end
end
```

**Use it from helpers that build per-slug image URLs** (e.g., hero/OG):

```elixir
def blog_hero_image(%{content_type: :blog, slug: slug}) do
  CodeMySpecWeb.ImageUrl.image_url("hero-#{slug}.webp")
end
def blog_hero_image(_), do: nil
```

No `File.exists?` check. The CDN bucket is the source of truth for what's served — keeping the helper in sync with the bucket via `File.exists?` on the local release would re-couple image edits to deploys (the original problem). Posts without a hero in the bucket render a broken image icon. Editorial discipline: always sync a hero before publishing.

If you need both webp and png variants (e.g., for a `<picture>` element with broader compatibility), build that into the template — keep the helper trivial.

### 4. Production env

```
IMAGES_HOST=https://images.example.com
```

Set in `envs/prod.env` (or your hosting platform's secrets store). Deploy once to ship the code change and the env var.

---

## Daily workflow after setup

The repo ships two operational scripts:

| Command | What it does |
|---------|---------------|
| `bin/sync-images` | `aws s3 sync priv/static/images/ s3://$IMAGES_BUCKET/`, accepts pass-through args (`--dryrun`, `--exclude`, `--include`). Bucket overridable via `IMAGES_BUCKET` env var. |
| `bin/purge-cdn <url-or-path>...` | Cloudflare cache purge for the given URLs. Accepts full URLs or relative paths (relative gets prefixed with `$IMAGES_HOST`). Reads `CLOUDFLARE_TOKEN` from `envs/dev.env` if not set. `--everything` flag does a full zone purge with a y/N confirmation. |

**New post / new image:**

```bash
# 1. Drop the master PNG into priv/static/images/ (commit it for the archive).
# 2. Heroes only — convert to WebP for ~85% smaller files (helper points at .webp):
cwebp -q 85 -quiet priv/static/images/hero-foo.png -o priv/static/images/hero-foo.webp

# 3. Push to CDN
bin/sync-images
```

Live within seconds. **No app deploy required.**

**Replacing an existing image** (same filename, new bytes):

```bash
bin/sync-images
bin/purge-cdn hero-foo.webp og-blog-foo.png
```

The purge bypasses Cloudflare's edge TTL so the new bytes are visible immediately instead of waiting up to the cache expiry.

**Sanity checks:**

```bash
bin/sync-images --dryrun                    # preview what would sync
bin/purge-cdn --everything                  # nuke entire zone cache (with confirm)
```

---

## Verifying the setup

```bash
# Direct to S3 website endpoint (should work right after upload)
curl -sI "http://images.example.com.s3-website-us-east-1.amazonaws.com/foo.png"

# Via Cloudflare (should work after DNS propagation + Page Rule active)
curl -sI "https://images.example.com/foo.png"
```

The second response should include `server: cloudflare` and `cf-cache-status:` headers. First-byte will be a `MISS`; subsequent requests `HIT`.

---

## When NOT to use this pattern

- **Private or auth-gated assets** — `SSL: Flexible` means CF→origin is HTTP. Bucket is also public-read. Use signed URLs and a private bucket if access control matters.
- **Assets that must never be public via direct S3 URL** — the bucket is public, so `https://images.example.com.s3-website-us-east-1.amazonaws.com/foo` works too. If that's a problem, use Cloudflare's "authenticated origin pulls" or a different fronting strategy.
- **Massive files (multi-GB)** — Cloudflare's free CDN has a 100 MB upload limit per request. Fine for images, not for video.
- **When you need on-the-fly transforms** (resize, format conversion) — add Cloudflare Images transformations on top, or use a different CDN with built-in transforms.

---

## Related

- `aws-s3-iam.md` — bucket creation, IAM users, ExAws credential setup
- `cloudflare-dns-tunnels.md` — Cloudflare DNS conventions, Tunnel setup, SSL modes
