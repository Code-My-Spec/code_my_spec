# DevOps Knowledge

Reference docs for infrastructure, deployment, and environment management.

> **Deploy stack:** CodeMySpec builds an image from the project's Dockerfile on a target-architecture Hetzner burst box at deploy time, pushes it to the app server's private registry, and deploys it with Kamal 2 + kamal-proxy. See `hetzner-docker-deploy.md`.

## When to read what

| Task | Read |
|------|------|
| Provision a Hetzner server or deploy with Kamal | `hetzner-docker-deploy.md` |
| Build and publish an image on the burst box | `hetzner-docker-deploy.md` |
| Dockerfile gotchas (envs touch, assets retry, ARM) | `hetzner-docker-deploy.md` |
| Manage local or SSM-backed secrets | `secrets-ssm.md` |
| Create S3 buckets or IAM users | `aws-s3-iam.md` |
| Configure ExAws credentials | `aws-s3-iam.md` |
| Add or change DNS records; dev tunnel; SSL modes | `cloudflare-dns-tunnels.md` |
| Serve static images from a CDN | `s3-cloudflare-image-host.md` |
| Migrate URLs without losing SEO link equity | `url-migration-redirects.md` |
| Transactional email (Resend + Cloudflare DNS) | `cloudflare-resend-email-setup.md` |
| Onboard an existing app with Kamal history | `onboarding-existing-kamal-app.md` |
| Read deployed logs and traces | `observability.md` |

## Deploy flow at a glance

```text
project HEAD + Dockerfile
  -> Provisioning.Builder on an account burst box matching the app host architecture
  -> private cms-registry on the app server, tagged with the short commit SHA
  -> Deploy.run from the burst box -> migrate -> health check -> Kamal traffic swap
```

The generated project does not contain a CI image-build workflow. The deploy does not wait for a workflow run or pull a CI-published GHCR image. `Provisioning.Registry` owns image references and retention; `Provisioning.Deploy` owns migration, health, and swap ordering.

## Key conventions

- **Image tag = short commit SHA.** The build happens at deploy time, for the architecture of the target app server.
- **Migrate before traffic swap.** Keep migrations additive while the previous container may still be serving.
- **Health is independent.** The proxy's `/health` probe must work without session, auth, or database access and must not redirect.
- **Private registry.** The builder pushes to the app server's private `cms-registry`; the app server pulls from it. Do not expose the registry on a public interface.
- **Project-specific resources.** Read the environment's server, DNS, and secret resources for actual hostnames and credentials. The SSM/Varlock guides describe apps using that secret layout.
