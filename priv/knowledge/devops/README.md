# DevOps Knowledge

Reference docs for infrastructure, deployment, and environment management.

> **Deploy stack (as of 2026):** Kamal 2 + kamal-proxy, images built in GitHub Actions → GHCR, app secrets in AWS SSM Parameter Store, Varlock for local secrets. This replaced the older Docker-Compose + Caddy + rsync + host-env-file model — see `hetzner-docker-deploy.md` for the migration note.

## When to read what

| Task | Read |
|------|------|
| Provision a Hetzner server (hcloud, firewall, snapshots) | `hetzner-docker-deploy.md` |
| Deploy with Kamal (`scripts/deploy`, kamal-proxy, migrate-before-swap) | `hetzner-docker-deploy.md` |
| Run prod + UAT (separate boxes, `APP_ENV`) | `hetzner-docker-deploy.md` |
| Build & push the image (multi-arch CI → GHCR) | `ci-image-build.md` |
| Dockerfile gotchas (envs touch, assets retry, ARM) | `ci-image-build.md` |
| Manage local secrets (Varlock, `.env.schema`) | `secrets-ssm.md` |
| Load prod secrets (SSM Parameter Store, `Secrets.load!/1`) | `secrets-ssm.md` |
| Seed / rotate secrets | `secrets-ssm.md` |
| Create S3 buckets or IAM users | `aws-s3-iam.md` |
| Combined S3 + SSM IAM user for the app | `aws-s3-iam.md` |
| Configure ExAws credentials | `aws-s3-iam.md` |
| Add/change DNS records; dev tunnel (cloudflared); SSL modes | `cloudflare-dns-tunnels.md` |
| Serve static images from a CDN | `s3-cloudflare-image-host.md` |
| Migrate URLs without losing SEO link equity | `url-migration-redirects.md` |
| Transactional email (Resend + Cloudflare DNS) | `cloudflare-resend-email-setup.md` |
| Onboard an existing app with its own Kamal history onto CodeMySpec | `onboarding-existing-kamal-app.md` |

## Typical infrastructure layout

```
                    Cloudflare DNS
                   ┌──────────────────────────────┐
                   │  myapp.com    → Prod box IP   │
                   │  uat.myapp.com→ UAT box IP    │
                   │  dev.myapp.com→ Tunnel        │
                   └──────────┬───────────────────┘
                              │
        ┌─────────────────────┴───────────────────────┐
        ▼                                              ▼
 ┌──────────────────────────┐              ┌──────────────────────────┐
 │ Hetzner PROD box         │              │ Hetzner UAT box          │
 │  kamal-proxy :443 (TLS)  │              │  kamal-proxy :443 (TLS)  │
 │   └── myapp app :4000    │              │   └── myapp app :4000    │
 │   └── other apps…        │              │   └── other apps…        │
 │  infra-postgres-1 (db_net)│             │  infra-postgres-1 (db_net)│
 └──────────┬───────────────┘              └──────────────────────────┘
            │ image pull                          ▲ boot-time secret pull
            ▼                                     │
   GHCR ghcr.io/code-my-spec/myapp:<sha>   AWS SSM /myapp/<env>/*  +  S3 buckets
   (built by GitHub Actions, multi-arch)   (SecureString, KMS)        myapp-<env>-files
```

## Deploy flow at a glance

```
git push ─► GitHub Actions (build multi-arch ─► GHCR :<sha>) ─► scripts/deploy
                                                                  ├─ gh run watch (gate)
                                                                  ├─ render AWS bootstrap creds from SSM
                                                                  ├─ kamal app exec --version=<sha> bin/migrate
                                                                  └─ kamal deploy --skip-push --version=<sha>
                                                                       └─ container boot: Secrets.load!/1 pulls /myapp/<env>/* from SSM
```

## Key conventions

- **Deploy only via `scripts/deploy`** — never raw `kamal deploy` (bootstrap creds must be rendered from SSM first).
- **Image tag = commit SHA.** CI builds it; the deploy pulls it with `--skip-push --version=<sha>`. Working tree must be clean.
- **Migrate before traffic swap** (`kamal app exec --version=<sha> /app/bin/migrate`), and keep migrations additive (two-phase destructive changes).
- **One `MIX_ENV=prod` image; `APP_ENV` selects prod/uat** and picks the SSM subtree.
- **Secrets:** local = Varlock (`.env.schema`, device-encrypted, committed); prod = AWS SSM `/<app>/<env>/*` (SecureString), loaded at boot. Kamal carries *only* the AWS bootstrap pair + GHCR token. Never `/opt/*.env` host files, never secrets in the repo.
- **One IAM user per app+env** covers S3 + SSM (`kms:Decrypt via ssm`). Hetzner has no instance role — static keys only.
- **Shared infra per box:** `kamal-proxy` (TLS/routing) and `infra-postgres-1` on a `db_net` network; multiple apps co-host.
- **Host-level concerns** (pg_dump cron, fail2ban, SSH hardening, `render-env`/`seed-secrets` tooling) live in a shared **`devops/` monorepo**, not per-app repos.
- Project-specific infra details (IPs, domains, bucket names) go in `.code_my_spec/devops/` or the app's `deploy/<provider>/`.
