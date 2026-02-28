# Hetzner + Docker Compose Deployment

Reference for provisioning Hetzner Cloud servers, running multi-environment Docker Compose stacks, and managing the full production lifecycle for a Phoenix/Elixir application.

**Stack:** Hetzner cax11 (ARM64, 4GB), Ubuntu 24.04, Docker Compose, Caddy 2, Postgres 17, Phoenix with Inertia.js/Svelte.

Sources:
- [Hetzner hcloud CLI how-to](https://community.hetzner.com/tutorials/howto-hcloud-cli/)
- [hcloud CLI releases](https://github.com/hetznercloud/cli/releases)
- [Caddy reverse_proxy directive](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy)
- [Docker Compose production docs](https://docs.docker.com/compose/how-tos/production/)
- [docker-rollout](https://github.com/wowu/docker-rollout)
- [Docker Compose pre-defined env vars](https://docs.docker.com/compose/how-tos/environment-variables/envvars/)
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
hcloud context create fuellytics
```

### SSH Key Management

```bash
# Upload your local public key
hcloud ssh-key create --name my-key --public-key-from-file ~/.ssh/id_ed25519.pub

# List keys
hcloud ssh-key list

# Delete a key
hcloud ssh-key delete my-key
```

### Server Provisioning

The cax11 is an ARM64 (Ampere Altra) shared-vCPU plan: 2 vCPU, 4 GB RAM, 40 GB SSD, ~3.79 EUR/month. Available in EU regions only (fsn1, nbg1, hel1).

```bash
# List available server types and images
hcloud server-type list
hcloud image list --type system | grep ubuntu

# Create server with SSH key and firewall
hcloud server create \
  --name fuellytics-prod \
  --type cax11 \
  --image ubuntu-24.04 \
  --location fsn1 \
  --ssh-key my-key \
  --firewall fuellytics-fw

# Get server IP
hcloud server describe fuellytics-prod | grep "Public Net"

# SSH in
ssh root@<IP>
```

### Firewall Rules

Create a firewall that allows only what is needed. SSH should be restricted to known IPs when possible.

```bash
# Create the firewall
hcloud firewall create --name fuellytics-fw

# Allow SSH from your IP only (replace YOUR_IP)
hcloud firewall add-rule fuellytics-fw \
  --direction in \
  --source-ips YOUR_IP/32 \
  --protocol tcp \
  --port 22 \
  --description "SSH from office/home"

# Allow HTTP (needed for Let's Encrypt ACME challenge)
hcloud firewall add-rule fuellytics-fw \
  --direction in \
  --source-ips 0.0.0.0/0 \
  --source-ips ::/0 \
  --protocol tcp \
  --port 80

# Allow HTTPS
hcloud firewall add-rule fuellytics-fw \
  --direction in \
  --source-ips 0.0.0.0/0 \
  --source-ips ::/0 \
  --protocol tcp \
  --port 443

# Allow HTTPS/UDP for HTTP/3 (QUIC)
hcloud firewall add-rule fuellytics-fw \
  --direction in \
  --source-ips 0.0.0.0/0 \
  --source-ips ::/0 \
  --protocol udp \
  --port 443

# Attach firewall to an existing server (if not set at creation time)
hcloud firewall apply-to-server fuellytics-fw --server fuellytics-prod

# Review rules
hcloud firewall describe fuellytics-fw
```

### Snapshots

Take a snapshot before risky operations (OS upgrades, major migrations). Snapshots cost ~0.01 EUR/GB/month and are not real-time backups — schedule them during low-traffic windows.

```bash
# Create snapshot (server can be running)
hcloud server create-image fuellytics-prod \
  --type snapshot \
  --description "Before Postgres 17 upgrade $(date +%Y-%m-%d)"

# List snapshots
hcloud image list --type snapshot

# Restore: create a new server from a snapshot
hcloud server create \
  --name fuellytics-restored \
  --type cax11 \
  --image <snapshot-id> \
  --ssh-key my-key \
  --firewall fuellytics-fw

# Delete old snapshot
hcloud image delete <snapshot-id>
```

---

## 2. Server Bootstrap (one-time)

After first SSH in as root:

```bash
# Update system
apt-get update && apt-get upgrade -y

# Install Docker
curl -fsSL https://get.docker.com | sh

# Install Docker Compose plugin (already bundled with Docker CE 24+)
docker compose version

# Create deploy user
useradd -m -s /bin/bash deploy
usermod -aG docker deploy

# Copy SSH key for deploy user
mkdir -p /home/deploy/.ssh
cp /root/.ssh/authorized_keys /home/deploy/.ssh/
chown -R deploy:deploy /home/deploy/.ssh
chmod 700 /home/deploy/.ssh
chmod 600 /home/deploy/.ssh/authorized_keys

# Create app directories
mkdir -p /opt/fuellytics/{app,uat}
chown -R deploy:deploy /opt/fuellytics
```

---

## 3. Multi-Environment Stack (prod + UAT on same host)

### The COMPOSE_PROJECT_NAME Approach

Docker Compose prefixes all resource names (containers, volumes, networks) with the project name. Two separate project names on the same host give fully isolated environments sharing no volumes or networks.

```
prod project:  fuellytics-prod-app-1, fuellytics-prod-db-1, fuellytics-prod-pgdata
uat project:   fuellytics-uat-app-1,  fuellytics-uat-db-1,  fuellytics-uat-pgdata
```

Both stacks share one Caddy reverse proxy that routes by hostname.

### Directory Layout on Server

```
/opt/fuellytics/
├── app/                     # prod — rsync target
│   ├── docker-compose.yml
│   ├── Dockerfile
│   ├── Caddyfile            # shared Caddyfile (mounted by Caddy service)
│   └── ...
├── uat/                     # uat — rsync target
│   ├── docker-compose.yml
│   ├── Dockerfile
│   └── ...
├── prod.env                 # prod secrets — never in git
└── uat.env                  # uat secrets — never in git
```

### Shared External Network for Caddy

Caddy only lives in one Compose project (prod). Both the prod and UAT app services must be on a shared network so Caddy can reach both.

```bash
# Create the shared network once on the server
docker network create caddy_proxy
```

### docker-compose.yml (prod)

```yaml
# /opt/fuellytics/app/docker-compose.yml
# Run with: docker compose -p fuellytics-prod --env-file /opt/fuellytics/prod.env up -d

services:
  db:
    image: postgres:17
    restart: unless-stopped
    volumes:
      - pgdata:/var/lib/postgresql/data
    environment:
      POSTGRES_USER: fuellytics
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: fuellytics_prod
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U fuellytics"]
      interval: 5s
      timeout: 5s
      retries: 5
    networks:
      - internal

  app:
    build: .
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    expose:
      - "4000"
    environment:
      DATABASE_URL: ecto://fuellytics:${POSTGRES_PASSWORD}@db/fuellytics_prod
      SECRET_KEY_BASE: ${SECRET_KEY_BASE}
      PHX_HOST: ${PHX_HOST}
      PHX_SERVER: "true"
      APP_BASE_URL: https://${PHX_HOST}
      TWILIO_ACCOUNT_SID: ${TWILIO_ACCOUNT_SID:-}
      TWILIO_AUTH_TOKEN: ${TWILIO_AUTH_TOKEN:-}
      TWILIO_MESSAGING_SERVICE_SID: ${TWILIO_MESSAGING_SERVICE_SID:-}
      TWILIO_FROM_NUMBER: ${TWILIO_FROM_NUMBER:-}
      TWILIO_STATUS_CALLBACK_URL: ${TWILIO_STATUS_CALLBACK_URL:-}
      STRIPE_SECRET_KEY: ${STRIPE_SECRET_KEY:-}
      STRIPE_WEBHOOK_SECRET: ${STRIPE_WEBHOOK_SECRET:-}
      ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY:-}
      AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID:-}
      AWS_SECRET_ACCESS_KEY: ${AWS_SECRET_ACCESS_KEY:-}
      AWS_REGION: ${AWS_REGION:-us-east-1}
      S3_BUCKET: ${S3_BUCKET:-fuellytics-uploads}
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost:4000/health || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 30s
    networks:
      - internal
      - caddy_proxy

  caddy:
    image: caddy:2
    restart: unless-stopped
    depends_on:
      app:
        condition: service_healthy
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - caddy_data:/data
      - caddy_config:/config
    networks:
      - caddy_proxy

volumes:
  pgdata:
  caddy_data:
  caddy_config:

networks:
  internal:
  caddy_proxy:
    external: true
```

### docker-compose.yml (uat)

Same structure, different database name, no Caddy service (prod Caddy routes to UAT too), app exposes on a different internal service name.

```yaml
# /opt/fuellytics/uat/docker-compose.yml
# Run with: docker compose -p fuellytics-uat --env-file /opt/fuellytics/uat.env up -d

services:
  db:
    image: postgres:17
    restart: unless-stopped
    volumes:
      - pgdata:/var/lib/postgresql/data
    environment:
      POSTGRES_USER: fuellytics
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: fuellytics_uat
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U fuellytics"]
      interval: 5s
      timeout: 5s
      retries: 5
    networks:
      - internal

  app:
    build: .
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    expose:
      - "4000"
    environment:
      DATABASE_URL: ecto://fuellytics:${POSTGRES_PASSWORD}@db/fuellytics_uat
      SECRET_KEY_BASE: ${SECRET_KEY_BASE}
      PHX_HOST: ${PHX_HOST}
      PHX_SERVER: "true"
      APP_BASE_URL: https://${PHX_HOST}
      # ... same vars as prod with uat-specific values
    networks:
      - internal
      - caddy_proxy

volumes:
  pgdata:

networks:
  internal:
  caddy_proxy:
    external: true
```

Key isolation facts:
- `-p fuellytics-prod` vs `-p fuellytics-uat` means all named volumes are separate: `fuellytics-prod_pgdata` vs `fuellytics-uat_pgdata`.
- Each stack has its own `internal` network that its `db` is on — the two databases cannot reach each other.
- Both `app` services join `caddy_proxy` so Caddy can reach them by their Docker DNS names.

### How Docker DNS Works Across Projects

Within the `caddy_proxy` network, Docker resolves container names using the format `<project>-<service>-<replica>`. The Caddyfile must use these full names:

```
fuellytics-prod-app-1   # prod app container
fuellytics-uat-app-1    # uat app container
```

---

## 4. Caddy Configuration

### Caddyfile — Multi-Domain Routing

```caddy
# /opt/fuellytics/app/Caddyfile

# Production
fuellytics.app {
    reverse_proxy fuellytics-prod-app-1:4000 {
        health_uri /health
        health_interval 10s
        health_timeout 5s
        health_status 2xx
    }
}

# UAT
uat.fuellytics.app {
    reverse_proxy fuellytics-uat-app-1:4000 {
        health_uri /health
        health_interval 10s
        health_timeout 5s
        health_status 2xx
    }
}
```

Auto-TLS notes:
- Caddy obtains Let's Encrypt certificates automatically for every named site block.
- DNS for both domains must point to the server's public IP before first deployment.
- Caddy stores certificates in the `caddy_data` volume — this volume must persist across redeploys.
- Port 80 must be reachable from the internet (ACME HTTP-01 challenge).

### Reloading Caddy Config

```bash
# Validate before reload
docker exec fuellytics-prod-caddy-1 caddy validate --config /etc/caddy/Caddyfile

# Graceful reload (no dropped connections)
docker exec fuellytics-prod-caddy-1 caddy reload --config /etc/caddy/Caddyfile
```

---

## 5. Deployment Workflow

### Deploy Script (prod)

The current deploy pattern is rsync + remote docker compose. This file lives at `scripts/deploy` in the project repo.

```bash
#!/usr/bin/env bash
# scripts/deploy — deploy prod
set -euo pipefail

SERVER="deploy@46.225.105.88"
APP_DIR="/opt/fuellytics/app"
ENV_FILE="/opt/fuellytics/prod.env"
PROJECT="fuellytics-prod"

echo "==> Syncing code to server..."
rsync -az --delete \
  --exclude='.git' \
  --exclude='_build' \
  --exclude='deps' \
  --exclude='assets/node_modules' \
  --exclude='.code_my_spec' \
  --exclude='test' \
  --exclude='envs' \
  ./ "$SERVER:$APP_DIR/"

echo "==> Building and restarting containers..."
ssh "$SERVER" "cd $APP_DIR && \
  docker compose -p $PROJECT --env-file $ENV_FILE up -d --build"

echo "==> Running migrations..."
ssh "$SERVER" "cd $APP_DIR && \
  docker compose -p $PROJECT --env-file $ENV_FILE exec app /app/bin/migrate"

echo "==> Done: https://fuellytics.app"
```

### Deploy Script (UAT)

```bash
#!/usr/bin/env bash
# scripts/deploy-uat
set -euo pipefail

SERVER="deploy@46.225.105.88"
APP_DIR="/opt/fuellytics/uat"
ENV_FILE="/opt/fuellytics/uat.env"
PROJECT="fuellytics-uat"

echo "==> Syncing code to server..."
rsync -az --delete \
  --exclude='.git' \
  --exclude='_build' \
  --exclude='deps' \
  --exclude='assets/node_modules' \
  --exclude='.code_my_spec' \
  --exclude='test' \
  --exclude='envs' \
  ./ "$SERVER:$APP_DIR/"

echo "==> Building and restarting containers..."
ssh "$SERVER" "cd $APP_DIR && \
  docker compose -p $PROJECT --env-file $ENV_FILE up -d --build"

echo "==> Running migrations..."
ssh "$SERVER" "cd $APP_DIR && \
  docker compose -p $PROJECT --env-file $ENV_FILE exec app /app/bin/migrate"

echo "==> Done: https://uat.fuellytics.app"
```

### Build Performance Notes

The cax11 has 4 GB RAM. The Elixir build stage with mix deps.compile is memory-intensive. If the Docker build OOMs:
- Build locally and push the image to a registry (GHCR, Docker Hub) instead of building on-server.
- Or upgrade temporarily to cax21 (8 GB) for builds, then scale back.

### Zero-Downtime Deployments with docker-rollout

Standard `docker compose up --build` stops the old container before starting the new one, causing 10–20 seconds of downtime. For production, use [docker-rollout](https://github.com/wowu/docker-rollout):

```bash
# Install on server (one-time)
mkdir -p /home/deploy/.docker/cli-plugins
curl -fsSL https://raw.githubusercontent.com/wowu/docker-rollout/main/docker-rollout \
  -o /home/deploy/.docker/cli-plugins/docker-rollout
chmod +x /home/deploy/.docker/cli-plugins/docker-rollout
```

Requirements for docker-rollout:
- The service must NOT have `container_name` set (it needs to scale).
- The service must NOT have `ports` mapped (use `expose` instead — Caddy proxies internally).
- A `healthcheck` must be defined so rollout knows when the new container is ready.

```bash
# In deploy script, replace:
docker compose -p $PROJECT --env-file $ENV_FILE up -d --build

# With:
docker compose -p $PROJECT --env-file $ENV_FILE build
docker compose -p $PROJECT --env-file $ENV_FILE up -d db   # ensure db is up
docker -p $PROJECT rollout app                              # zero-downtime swap
```

docker-rollout scales app to 2 replicas, waits for the new one to pass health checks, then removes the old one. Caddy's active health checks stop routing to the old container during the window.

Note: If you use docker-rollout, the Caddyfile upstream must use the Docker network DNS name pattern, not a hardcoded container name. Configure Caddy to upstream to the service using a load-balanced approach or use caddy-docker-proxy.

---

## 6. Phoenix Migrations in Docker

Phoenix releases generated with `mix phx.gen.release` include a `bin/migrate` script that runs `App.Release.migrate()`. This boots a slim Erlang VM, starts only the Repo, runs all pending migrations, then exits.

The `lib/fuellytics/release.ex` module contains:

```elixir
defmodule Fuellytics.Release do
  @app :fuellytics

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
```

Migration commands:

```bash
# Run all pending migrations
docker compose -p fuellytics-prod --env-file /opt/fuellytics/prod.env \
  exec app /app/bin/migrate

# Rollback one version (requires eval)
docker compose -p fuellytics-prod --env-file /opt/fuellytics/prod.env \
  exec app /app/bin/fuellytics eval \
  'Fuellytics.Release.rollback(Fuellytics.Repo, 20260101000000)'

# Interactive shell (for debugging)
docker compose -p fuellytics-prod --env-file /opt/fuellytics/prod.env \
  exec app /app/bin/fuellytics remote
```

The `DATABASE_URL` and `SECRET_KEY_BASE` env vars must be available when running migrate — they are present because the exec command runs inside the already-running container.

---

## 7. Database Management

### Manual Backup

```bash
# Dump prod database to timestamped file
docker exec fuellytics-prod-db-1 \
  pg_dump -U fuellytics fuellytics_prod \
  | gzip > /opt/fuellytics/backups/prod-$(date +%Y%m%d-%H%M%S).sql.gz

# Dump UAT database
docker exec fuellytics-uat-db-1 \
  pg_dump -U fuellytics fuellytics_uat \
  | gzip > /opt/fuellytics/backups/uat-$(date +%Y%m%d-%H%M%S).sql.gz
```

### Automated Backups via Cron

```bash
# On the server, as deploy user
mkdir -p /opt/fuellytics/backups
crontab -e
```

Add:
```
# Prod backup at 3:00 AM daily
0 3 * * * docker exec fuellytics-prod-db-1 pg_dump -U fuellytics fuellytics_prod | gzip > /opt/fuellytics/backups/prod-$(date +\%Y\%m\%d-\%H\%M\%S).sql.gz

# UAT backup at 3:30 AM daily
30 3 * * * docker exec fuellytics-uat-db-1 pg_dump -U fuellytics fuellytics_uat | gzip > /opt/fuellytics/backups/uat-$(date +\%Y\%m\%d-\%H\%M\%S).sql.gz

# Purge backups older than 14 days
0 4 * * * find /opt/fuellytics/backups -name "*.sql.gz" -mtime +14 -delete
```

### Restore

```bash
# Stop the app to prevent new connections during restore
docker compose -p fuellytics-prod --env-file /opt/fuellytics/prod.env stop app

# Drop and recreate the database
docker exec fuellytics-prod-db-1 \
  psql -U fuellytics -c "DROP DATABASE fuellytics_prod;"
docker exec fuellytics-prod-db-1 \
  psql -U fuellytics -c "CREATE DATABASE fuellytics_prod;"

# Restore from dump
gunzip -c /opt/fuellytics/backups/prod-20260301-030000.sql.gz \
  | docker exec -i fuellytics-prod-db-1 \
    psql -U fuellytics fuellytics_prod

# Restart app
docker compose -p fuellytics-prod --env-file /opt/fuellytics/prod.env start app
```

### Accessing Postgres Directly

```bash
# Interactive psql session
docker exec -it fuellytics-prod-db-1 psql -U fuellytics fuellytics_prod

# Run a one-off query
docker exec fuellytics-prod-db-1 \
  psql -U fuellytics fuellytics_prod -c "SELECT count(*) FROM transactions;"
```

### Copying Prod Data to UAT

```bash
# Dump prod
docker exec fuellytics-prod-db-1 \
  pg_dump -U fuellytics fuellytics_prod > /tmp/prod-snapshot.sql

# Restore into UAT
docker exec fuellytics-uat-db-1 \
  psql -U fuellytics -c "DROP DATABASE fuellytics_uat; CREATE DATABASE fuellytics_uat;"
docker exec -i fuellytics-uat-db-1 \
  psql -U fuellytics fuellytics_uat < /tmp/prod-snapshot.sql

rm /tmp/prod-snapshot.sql
```

---

## 8. Secrets Management

### Env Files on Server

Secrets live at `/opt/fuellytics/{prod,uat}.env` on the server. These files are:
- Never committed to the repo (enforced by `.gitignore`)
- Owned by the `deploy` user with mode `600`
- Passed to `docker compose` via `--env-file`

```bash
# Set permissions (one-time)
chmod 600 /opt/fuellytics/prod.env
chmod 600 /opt/fuellytics/uat.env
chown deploy:deploy /opt/fuellytics/*.env
```

### Env File Format

```bash
# /opt/fuellytics/prod.env
POSTGRES_PASSWORD=<strong-random-password>
SECRET_KEY_BASE=<64-byte-hex-from-mix-phx-gen-secret>
PHX_HOST=fuellytics.app
TWILIO_ACCOUNT_SID=ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
TWILIO_AUTH_TOKEN=<token>
TWILIO_MESSAGING_SERVICE_SID=MGxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
TWILIO_FROM_NUMBER=+15551234567
TWILIO_STATUS_CALLBACK_URL=https://fuellytics.app/twilio/status
STRIPE_SECRET_KEY=sk_live_...
STRIPE_WEBHOOK_SECRET=whsec_...
ANTHROPIC_API_KEY=sk-ant-...
AWS_ACCESS_KEY_ID=AKIA...
AWS_SECRET_ACCESS_KEY=<key>
AWS_REGION=us-east-1
S3_BUCKET=fuellytics-uploads
```

```bash
# /opt/fuellytics/uat.env — same keys, different values
POSTGRES_PASSWORD=<different-uat-password>
SECRET_KEY_BASE=<different-secret>
PHX_HOST=uat.fuellytics.app
TWILIO_STATUS_CALLBACK_URL=https://uat.fuellytics.app/twilio/status
STRIPE_SECRET_KEY=sk_test_...
STRIPE_WEBHOOK_SECRET=whsec_...
S3_BUCKET=fuellytics-uploads-uat
# ... etc
```

### Setting Secrets via SSH

```bash
# Generate a new secret key base
mix phx.gen.secret

# Write a secret to the server without a local copy
ssh deploy@46.225.105.88 \
  "echo 'SECRET_KEY_BASE=<value>' >> /opt/fuellytics/prod.env"

# Or edit directly on server
ssh deploy@46.225.105.88 "nano /opt/fuellytics/prod.env"

# Verify the file (omit actual values in logs)
ssh deploy@46.225.105.88 "grep -o '^[A-Z_]*=' /opt/fuellytics/prod.env"
```

### Runtime Config and Dotenvy

This Phoenix app uses Dotenvy in `config/runtime.exs`. At release startup, Dotenvy loads env files from `$RELEASE_ROOT/envs/`. In Docker, all secrets are passed as container env vars (via the `--env-file` flag), so Dotenvy falls through to `System.get_env()`. The `envs/.env` and `envs/prod.env` inside the Docker image are intentionally empty (created during `docker build` to satisfy Dotenvy's `source!` call):

```dockerfile
# In Dockerfile — prevents Dotenvy crash on missing file
RUN mkdir -p envs && touch envs/.env envs/prod.env
```

The real values come from `environment:` in docker-compose.yml, which in turn reads from the `--env-file` flag.

---

## 9. Server Hardening

### SSH: Key-Only Auth, No Root Login

After setting up the `deploy` user with SSH keys:

```bash
# Edit SSH config
nano /etc/ssh/sshd_config
```

Set these values:
```
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
# Restrict to deploy user only
AllowUsers deploy
```

```bash
# Test config before restarting
sshd -t

# Restart SSH daemon
systemctl restart sshd
```

Keep your current session open and test in a second terminal before closing.

### UFW Firewall (Host-Level)

Note: Docker bypasses UFW by writing its own iptables rules. The Hetzner cloud firewall (applied at the network edge) is the more reliable layer for controlling inbound access to Docker-published ports. Use UFW primarily to protect non-Docker services.

```bash
apt-get install -y ufw

# Default: deny all inbound, allow all outbound
ufw default deny incoming
ufw default allow outgoing

# Allow SSH (use your actual port, default 22)
ufw allow 22/tcp

# Enable
ufw enable

# Status
ufw status verbose
```

For controlling Docker-exposed ports at the iptables level, use the DOCKER-USER chain:

```bash
# Block all access to Docker ports except via Caddy (example)
# Add to /etc/ufw/after.rules or use iptables directly
iptables -I DOCKER-USER -i eth0 -j DROP
iptables -I DOCKER-USER -i eth0 -s YOUR_IP -j ACCEPT
```

The cleaner solution for a simple single-server setup is to rely on the Hetzner cloud firewall (configured via hcloud) rather than managing iptables/UFW interaction with Docker. The Hetzner firewall blocks at the network level before traffic reaches the server.

### fail2ban

fail2ban protects SSH from brute-force attacks. On a Docker host, configure it to use the DOCKER-USER iptables chain if you also want to protect Docker-exposed services.

```bash
apt-get install -y fail2ban

# Create local jail config
cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5

[sshd]
enabled  = true
port     = ssh
logpath  = %(sshd_log)s
backend  = %(sshd_backend)s
EOF

systemctl enable fail2ban
systemctl start fail2ban

# Check status
fail2ban-client status
fail2ban-client status sshd
```

### Unattended Upgrades

Automatically apply security updates without manual intervention:

```bash
apt-get install -y unattended-upgrades

# Enable
dpkg-reconfigure -plow unattended-upgrades

# Configuration lives in /etc/apt/apt.conf.d/50unattended-upgrades
# Verify it will apply security updates:
grep "Unattended-Upgrade::Allowed-Origins" /etc/apt/apt.conf.d/50unattended-upgrades
```

---

## 10. Operational Runbook

### Check Service Status

```bash
# All containers across both stacks
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Logs
docker logs fuellytics-prod-app-1 --tail 50 -f
docker logs fuellytics-prod-db-1 --tail 20

# Health check status
docker inspect fuellytics-prod-app-1 | jq '.[0].State.Health'
```

### Restart a Service

```bash
# Restart app without rebuilding
docker compose -p fuellytics-prod --env-file /opt/fuellytics/prod.env restart app

# Rebuild and restart
docker compose -p fuellytics-prod --env-file /opt/fuellytics/prod.env up -d --build app
```

### Disk Usage

```bash
# Docker disk usage
docker system df

# Prune unused images (safe — only removes untagged/dangling)
docker image prune -f

# Prune build cache (frees space after failed builds)
docker builder prune -f
```

### Caddy TLS Certificate Status

```bash
# List managed certificates
docker exec fuellytics-prod-caddy-1 caddy list-certificates

# Force certificate renewal (usually not needed — Caddy auto-renews at 2/3 of lifetime)
docker exec fuellytics-prod-caddy-1 caddy reload --config /etc/caddy/Caddyfile
```

### Common Issues

**Build runs out of memory on cax11:**
The Elixir compiler is memory-hungry. Symptoms: `Killed` during `mix deps.compile`. Options:
1. Add a swap file temporarily: `fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile`
2. Build the Docker image on your local ARM Mac (`docker buildx build --platform linux/arm64`) and push to GHCR, then pull on the server.

**Container exits immediately after start:**
Run interactively to see the error:
```bash
docker compose -p fuellytics-prod --env-file /opt/fuellytics/prod.env run --rm app /app/bin/fuellytics eval ":ok"
```

**Caddy not routing to UAT:**
Ensure the UAT app container is on the `caddy_proxy` network:
```bash
docker network inspect caddy_proxy | jq '.[0].Containers | keys'
```

**Migrations fail with "relation already exists":**
This is usually safe — Ecto migrations are idempotent. Check the migration log:
```bash
docker compose -p fuellytics-prod --env-file /opt/fuellytics/prod.env \
  exec app psql -h db -U fuellytics fuellytics_prod \
  -c "SELECT version, inserted_at FROM schema_migrations ORDER BY inserted_at DESC LIMIT 10;"
```
