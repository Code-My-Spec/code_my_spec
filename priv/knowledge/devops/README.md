# DevOps Knowledge

Reference docs for infrastructure, deployment, and environment management.

## When to read what

| Task                                  | Read                          |
|---------------------------------------|-------------------------------|
| Create S3 buckets or IAM users        | `aws-s3-iam.md`              |
| Configure ExAws credentials           | `aws-s3-iam.md`              |
| Add/change DNS records                | `cloudflare-dns-tunnels.md`  |
| Set up dev tunnel (cloudflared)       | `cloudflare-dns-tunnels.md`  |
| SSL/TLS with Caddy + Cloudflare      | `cloudflare-dns-tunnels.md`  |
| Provision a Hetzner server            | `hetzner-docker-deploy.md`   |
| Deploy with Docker Compose            | `hetzner-docker-deploy.md`   |
| Run prod + UAT on same host           | `hetzner-docker-deploy.md`   |
| Back up or restore Postgres           | `hetzner-docker-deploy.md`   |
| Manage secrets on server              | `hetzner-docker-deploy.md`   |

## Infrastructure overview

```
                    Cloudflare DNS
                   ┌──────────────────────────────┐
                   │  fuellytics.app → Hetzner IP  │
                   │  uat.fuellytics.app → same    │
                   │  dev.fuellytics.app → Tunnel  │
                   └──────────┬───────────────────┘
                              │
              ┌───────────────┼───────────────┐
              │               │               │
         fuellytics.app  uat.fuellytics.app  dev.fuellytics.app
              │               │               │
              ▼               ▼               ▼
         ┌─────────────────────────┐    Developer laptop
         │  Hetzner cax11 (ARM)    │    (cloudflared tunnel)
         │                         │
         │  Caddy :443 ──┬── prod app :4000 ── prod db
         │               └── uat app  :4001 ── uat db
         └─────────────────────────┘
                              │
                        AWS S3 buckets
                   ┌──────────┴──────────┐
                   │ fuellytics-uploads   │  (prod)
                   │ fuellytics-uploads-uat│  (uat)
                   └─────────────────────┘
```

## Environments

| Env    | Domain                | Infra              | S3 Bucket               |
|--------|-----------------------|---------------------|-------------------------|
| dev    | `dev.fuellytics.app`  | Local + CF Tunnel   | local disk              |
| uat    | `uat.fuellytics.app`  | Hetzner (Docker)    | `fuellytics-uploads-uat`|
| prod   | `fuellytics.app`      | Hetzner (Docker)    | `fuellytics-uploads`    |

## Key conventions

- Secrets live on the server at `/opt/fuellytics/{prod,uat}.env` — never in the repo
- Deploy scripts live in `scripts/` at project root
- Cloudflare Tunnel GenServer lives in `client_utils` (shared lib) — not per-project
- ExAws uses the standard credential chain: env vars → `~/.aws/credentials` → IAM role
