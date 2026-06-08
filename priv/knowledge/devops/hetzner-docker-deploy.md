# Hetzner + Kamal Deployment

Reference for provisioning Hetzner Cloud servers and deploying a Phoenix/Elixir app with **Kamal 2**. Images are built in CI and pushed to GHCR; Kamal pulls them onto the host and **kamal-proxy** terminates TLS and routes by hostname. App secrets come from AWS SSM at boot.

**Stack:** Hetzner cax11 (ARM64) / shared-vCPU (amd64), Ubuntu 24.04, Kamal 2 + kamal-proxy, Postgres 17 (shared `infra-postgres-1` container on a `db_net` network), GHCR for images, AWS SSM Parameter Store for secrets.

> **History:** this project deployed with Docker Compose + Caddy + rsync until early 2026. Both `market_my_spec` and `get_ai_traffic` migrated to the Kamal stack below. If you find a `docker-compose.prod.yml` + `Caddyfile` in a repo, it's vestigial — the live path is `scripts/deploy` → Kamal.

Companion playbooks:
- `ci-image-build.md` — the GitHub Actions multi-arch build that produces the GHCR image this deploy pulls.
- `secrets-ssm.md` — Varlock (local) → SSM Parameter Store (prod) secret lifecycle that `.kamal/secrets-common` and `Secrets.load!/1` depend on.
- `aws-s3-iam.md` — the IAM user (S3 + SSM) the running container uses.

Sources:
- [Kamal docs](https://kamal-deploy.org/)
- [kamal-proxy](https://github.com/basecamp/kamal-proxy)
- [hcloud CLI](https://github.com/hetznercloud/cli/releases)
- [Phoenix releases guide](https://hexdocs.pm/phoenix/releases.html)

---

## 1. Hetzner Cloud CLI (hcloud)

### Installation

```bash
# macOS
brew install hcloud

# Linux
curl -fsSL https://github.com/hetznercloud/cli/releases/latest/download/hcloud-linux-amd64.tar.gz | tar xz
sudo mv hcloud /usr/local/bin/

# Authenticate — paste API token from Hetzner console
hcloud context create myproject
```

### SSH Key Management

```bash
hcloud ssh-key create --name my-key --public-key-from-file ~/.ssh/id_ed25519.pub
hcloud ssh-key list
hcloud ssh-key delete my-key
```

### Server Provisioning

cax11 is an ARM64 (Ampere Altra) shared-vCPU plan: 2 vCPU, 4 GB RAM, 40 GB SSD, ~3.79 EUR/month, EU regions only (fsn1, nbg1, hel1). A `cx`/`cpx` amd64 plan works too — match the box arch to the image arch you build in CI (`builder.arch` in `config/deploy.yml`).

```bash
hcloud server-type list
hcloud image list --type system | grep ubuntu

hcloud server create \
  --name myproject-prod \
  --type cax11 \
  --image ubuntu-24.04 \
  --location fsn1 \
  --ssh-key my-key \
  --firewall myproject-fw

hcloud server describe myproject-prod | grep "Public Net"
ssh root@<IP>
```

### Firewall Rules

kamal-proxy listens on 80/443. Open those plus SSH.

```bash
hcloud firewall create --name myproject-fw

# SSH from your IP only
hcloud firewall add-rule myproject-fw \
  --direction in --source-ips YOUR_IP/32 --protocol tcp --port 22

# HTTP (ACME HTTP-01 challenge) + HTTPS + HTTP/3
hcloud firewall add-rule myproject-fw --direction in --source-ips 0.0.0.0/0 --source-ips ::/0 --protocol tcp --port 80
hcloud firewall add-rule myproject-fw --direction in --source-ips 0.0.0.0/0 --source-ips ::/0 --protocol tcp --port 443
hcloud firewall add-rule myproject-fw --direction in --source-ips 0.0.0.0/0 --source-ips ::/0 --protocol udp --port 443
```

### Snapshots

Take a snapshot before risky operations (OS upgrades, major migrations). ~0.01 EUR/GB/month.

```bash
hcloud server create-image myproject-prod --type snapshot \
  --description "Before Postgres 17 upgrade $(date +%Y-%m-%d)"
hcloud image list --type snapshot
```

---

## 2. Server Bootstrap (one-time)

Kamal installs Docker itself on first deploy (`kamal server bootstrap`), but for a shared box you provision the Postgres container and the shared network once.

```bash
# Update + Docker (kamal will also do this; harmless if pre-installed)
apt-get update && apt-get upgrade -y
curl -fsSL https://get.docker.com | sh
docker compose version

# Shared app network — every app's container attaches here to reach Postgres.
docker network create db_net

# Shared Postgres (one per host, all apps use their own DB + per-app user).
docker run -d --name infra-postgres-1 --restart unless-stopped \
  --network db_net \
  -e POSTGRES_PASSWORD=<superuser-pw> \
  -v pgdata:/var/lib/postgresql/data \
  postgres:17
```

Kamal connects over SSH as `root` (`ssh: { user: root }` in `config/deploy.yml`). Hardening (key-only SSH, fail2ban, unattended-upgrades) is in §9; in practice these and the Postgres provisioning live in a shared **`devops/` monorepo**, not in each app repo.

---

## 3. The Kamal Deploy Model

One `config/deploy.yml` per environment. kamal-proxy (started automatically) owns :80/:443, terminates TLS via Let's Encrypt, and routes by `Host` — so multiple apps coexist on one box with no shared Caddy and no `COMPOSE_PROJECT_NAME`.

```yaml
# config/deploy.yml (prod)
service: myapp
image: code-my-spec/myapp           # GHCR repo (registry.server prepended)

servers:
  web:
    hosts:
      - <PROD_IP>
    options:
      network: db_net               # pre-attach so the container can reach infra-postgres-1 at boot

proxy:
  ssl: true                         # kamal-proxy gets a Let's Encrypt cert for `host`
  host: myapp.com
  app_port: 4000
  healthcheck:
    path: /health                   # gates the traffic swap (see §6)

registry:
  server: ghcr.io
  username: johns10
  password:
    - KAMAL_REGISTRY_PASSWORD       # = `gh auth token`, exported by scripts/deploy

builder:
  arch: amd64                       # match the host arch; arm64 for cax11 boxes
  local: true                      # not actually invoked — deploys use --skip-push (CI built the image)

env:
  clear:
    APP_ENV: prod                   # runtime env discriminator (see secrets-ssm.md)
    AWS_REGION: us-east-1
  secret:
    - AWS_ACCESS_KEY_ID             # bootstrap creds only — app secrets come from SSM at boot
    - AWS_SECRET_ACCESS_KEY

ssh:
  user: root
```

Key facts:
- **No Caddy, no Compose.** kamal-proxy is the reverse proxy. A `Caddyfile` in the repo is reference-only.
- **`options.network: db_net`** attaches the container to the shared network at create time so `DATABASE_URL=ecto://...@infra-postgres-1/myapp_prod` resolves.
- **`env.secret` carries only AWS bootstrap creds** (+ the GHCR token). Every other secret is fetched from SSM at boot — see `secrets-ssm.md`.
- **`APP_ENV`** (not `MIX_ENV`) selects prod vs uat at runtime, so one `MIX_ENV=prod` image serves both.

### Multi-environment

Separate boxes, one `config/deploy.<env>.yml` each (e.g. `config/deploy.uat.yml` → `<UAT_IP>`, `host: uat.myapp.com`, `APP_ENV: uat`, often `arch: arm64`). This replaces the old single-host `COMPOSE_PROJECT_NAME` split — isolation is physical, and each box can co-host unrelated apps (prod box also runs `market_my_spec`; uat box also runs `fuellytics`).

---

## 4. Image Build (CI)

Images are **not** built on the deploy machine. GitHub Actions builds a multi-arch image on push to `master` and pushes it to GHCR tagged with the commit SHA. `scripts/deploy` waits for that build, then `kamal deploy --skip-push --version=<sha>` pulls it. Full detail: **`ci-image-build.md`**.

---

## 5. Deployment Workflow

`scripts/deploy` is the only supported entry point — never run `kamal deploy` directly (the bootstrap creds must be rendered from SSM first).

```bash
#!/usr/bin/env bash
# scripts/deploy — deploy prod
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$REPO_ROOT"
DEVOPS_DIR="${DEVOPS_DIR:-$HOME/Documents/github/devops}"

# 1. Clean tree (Kamal versions by commit SHA)
[[ -z "$(git status --porcelain)" ]] || { echo "commit/stash first" >&2; git status --short >&2; exit 1; }
SHA=$(git rev-parse HEAD); BRANCH=$(git rev-parse --abbrev-ref HEAD)

# 2. Push and wait for the CI build to land in GHCR
git push origin "$BRANCH"
sleep 5
RUN_ID=$(gh run list --workflow=build.yml --branch="$BRANCH" --limit=1 --json databaseId --jq '.[0].databaseId')
gh run watch "$RUN_ID" --exit-status --interval 10

# 3. GHCR pull token + render AWS bootstrap creds from SSM into a temp file
export KAMAL_REGISTRY_PASSWORD; KAMAL_REGISTRY_PASSWORD=$(gh auth token)
ENV_FILE=$(mktemp); trap 'rm -f "$ENV_FILE"' EXIT
"$DEVOPS_DIR/scripts/render-env" myapp prod --out "$ENV_FILE" || { echo "render-env failed; run 'aws sso login'" >&2; exit 1; }
set -a; source "$ENV_FILE"; set +a
unset AWS_SESSION_TOKEN AWS_SECURITY_TOKEN AWS_PROFILE     # container needs the long-term IAM pair, not your SSO STS token
for r in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
  [[ -n "${!r:-}" ]] || { echo "ERROR: $r empty after render-env; refusing to deploy" >&2; exit 1; }
done

# 4. Migrate against the NEW image BEFORE swapping traffic
kamal app exec --version="$SHA" "/app/bin/migrate"

# 5. Swap traffic
kamal deploy --skip-push --version="$SHA" "$@"
```

> **Why the temp-file + hard-fail guard (steps 3):** `source <(render-env ...)` (process substitution) swallows `render-env`'s exit code. If SSO is stale it prints nothing, `source` consumes nothing, and the deploy proceeds with **empty** AWS keys — Kamal then pushes an empty env-file to the host that survives across every later `kamal app exec`, bricking prod secrets. Render to a temp file, check the exit code, and refuse to deploy on empty creds.

### First deploy per environment (bootstrap)

The migrate-before-swap order assumes Kamal's per-host env-file already exists. On a brand-new env it doesn't, so the very first deploy is manual:

```bash
kamal deploy --skip-push --version=<sha> -c config/deploy.yml
kamal app exec --version=<sha> -c config/deploy.yml /app/bin/migrate
```

Thereafter use `scripts/deploy`.

---

## 6. Migrations & Health

### Migrate before traffic swap

`kamal app exec --version=<sha> /app/bin/migrate` boots a one-off container from the **new** image, runs migrations, and exits. The currently-serving (old) container keeps handling traffic against the now-migrated schema until `kamal deploy` swaps it in.

`bin/migrate` is a release overlay (`rel/overlays/bin/migrate`):

```sh
#!/bin/sh
set -eu
cd -P -- "$(dirname -- "$0")"
exec ./myapp eval MyApp.Release.migrate
```

> **Additive-only constraint:** during the migrate-then-swap window the **old** code runs against the **new** schema. A destructive migration (drop column the old code still reads) breaks the old container in that gap. Two-phase it: deploy code that stops reading the column, then a later deploy that drops it.

### Health endpoint

kamal-proxy gates the swap on `proxy.healthcheck.path`. Define it **outside all router pipelines** (no session, CSRF, auth, or DB):

```elixir
# router.ex
scope "/", MyAppWeb do
  get "/health", PageController, :health   # no :browser / :api pipeline
end
# page_controller.ex
def health(conn, _params), do: send_resp(conn, 200, "ok")
```

**`force_ssl` gotcha:** kamal-proxy's internal health probe hits the app port directly (plain HTTP, no `X-Forwarded-Proto`). If you use `force_ssl`, exclude the health path or it 301s and the probe fails:

```elixir
config :myapp, MyAppWeb.Endpoint,
  force_ssl: [rewrite_on: [:x_forwarded_proto], exclude: ["/up", "localhost", "127.0.0.1"]]
```

(`get_ai_traffic` uses `/health` and reports no exclusion needed; `market_my_spec` uses `/up` and excludes it. Match the path to your proxy config and test the probe.)

---

## 7. Secrets

`.kamal/secrets-common` is a Dotenv file Kamal reads; `${VAR}` tokens are interpolated from the deploy shell (populated by `scripts/deploy`). **It carries only bootstrap creds — never app secrets:**

```bash
# .kamal/secrets-common
KAMAL_REGISTRY_PASSWORD=${KAMAL_REGISTRY_PASSWORD}
AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
```

At container boot, `MyApp.Secrets.load!/1` pulls everything under `/myapp/<APP_ENV>/` from SSM into the OS env before `runtime.exs` reads it. Full lifecycle (Varlock locally, SSM in prod, seeding, rotation): **`secrets-ssm.md`**.

---

## 8. Database Management

DB is the shared `infra-postgres-1` container on `db_net`, with a per-app database and per-app user (e.g. `myapp_prod_app`). `DATABASE_URL` is an SSM param.

```bash
# Manual dump (run on the host)
docker exec infra-postgres-1 pg_dump -U myapp_prod_app myapp_prod | gzip > /opt/backups/myapp-prod-$(date +%Y%m%d-%H%M%S).sql.gz

# Restore
gunzip -c backup.sql.gz | docker exec -i infra-postgres-1 psql -U myapp_prod_app myapp_prod
```

In practice, scheduled `pg_dump` cron + retention purge live in the shared **`devops/` monorepo** (one backup job for the shared Postgres), not per-app.

---

## 9. Server Hardening

Typically applied once per host from the shared `devops/` monorepo.

```bash
# /etc/ssh/sshd_config — key-only
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
```

```bash
# fail2ban
apt-get install -y fail2ban
printf '[sshd]\nenabled = true\nbantime = 3600\nfindtime = 600\nmaxretry = 5\n' > /etc/fail2ban/jail.local
systemctl enable --now fail2ban

# unattended upgrades
apt-get install -y unattended-upgrades && dpkg-reconfigure -plow unattended-upgrades
```

> Docker bypasses UFW by writing its own iptables rules. The **Hetzner cloud firewall** (network edge, §1) is the reliable control for inbound access. kamal-proxy publishes 80/443; nothing else should be exposed.

---

## 10. Operational Runbook

Kamal is the primary tool — most ops don't need a raw SSH session.

```bash
# Status / logs
kamal app details
kamal app logs -f
kamal app logs --grep ERROR

# Shell / IEx in the running container
kamal app exec -i --reuse "/app/bin/myapp remote"

# One-off command against current version
kamal app exec "/app/bin/myapp eval ':ok'"

# Rollback to a previous SHA (image still in GHCR)
kamal rollback <old-sha>

# kamal-proxy state (routes, certs)
kamal proxy details
```

### Common Issues

**Every request 500s right after a "successful" deploy** — migrations didn't run before the swap. Confirm `scripts/deploy` ran `kamal app exec --version=$SHA /app/bin/migrate` *before* `kamal deploy`.

**Container boots then exits / "No SSM parameters found"** — bootstrap AWS creds are empty or the IAM user can't read `/myapp/<env>/*`. Check `secrets-ssm.md` and the IAM policy in `aws-s3-iam.md`. Re-run `aws sso login`.

**kamal-proxy health probe fails / endless redirect** — `force_ssl` is 301-ing the health path. Exclude it (§6).

**`DATABASE_URL`/host unreachable** — the container isn't on `db_net`. Confirm `servers.web.options.network: db_net` and that `infra-postgres-1` is running on the same network.

**Deploy proceeds with empty AWS keys** — you bypassed `scripts/deploy` or used process substitution for `render-env`. Always go through the script (§5).
