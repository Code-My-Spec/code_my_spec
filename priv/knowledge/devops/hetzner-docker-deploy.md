# Hetzner + Kamal Deployment

Reference for provisioning Hetzner Cloud servers and deploying a Phoenix/Elixir app with **Kamal 2**. At deploy time, `CodeMySpec.Provisioning.Builder` builds the project's Dockerfile on an account burst box with the same architecture as the app server. The builder pushes the image to the private registry on the app server; Kamal pulls that image and **kamal-proxy** terminates TLS and routes by hostname. The generated project has no CI image-build workflow.

**Stack:** Hetzner ARM64 or x86 servers, Ubuntu 24.04, Kamal 2 + kamal-proxy, an app-server-local `cms-registry` container, and the project's runtime secret mechanism. The provisioning code is the authority for server sizes, networking, registry credentials, and deploy commands.

Companion playbooks:
- `secrets-ssm.md` — SSM and Varlock guidance for apps that use that secret layout.
- `aws-s3-iam.md` — S3 and SSM IAM guidance for those apps.

> **History:** Some existing apps used Docker Compose + Caddy + rsync, then a manual Kamal deployment that pulled CI-built GHCR images. Those examples do not describe the current CodeMySpec provisioning path.

## Provisioning and networking

The provisioning server step creates or finds the app server and starts its private registry. `CodeMySpec.Provisioning.Registry` uses a `cms-registry` container on that server, backed by a local volume. The builder and app server can reach its private-network address; it is not exposed publicly. Projects sharing a server have separate repository paths and registry credentials. Registry pruning enforces the retained-image count.

The builder uses an account-level burst box: `cax21` for ARM64 or `cpx31` for x86 by default. It can be reused across project builds, and `BurstBox.Lifecycle` checks after each build whether to release it. The image must be built for the architecture Hetzner reports for the target app server; do not assume a requested server type was actually provisioned. A single-architecture image for the target host is sufficient.

Open SSH and the ports needed by kamal-proxy on the app server. Keep the registry on the private network. For project-specific hostnames, IPs, and credentials, consult the environment's provisioning resources rather than copying values from another app.

## Image build and deploy flow

The Dockerfile is the build input. Nothing is built when the project is created. The deploy step reads the project's head commit, uses its first 12 characters as the image tag, gets the app server's architecture and private registry address, then calls `Provisioning.Builder`. `Builder.Remote` delivers that commit to the burst box, runs `docker build`, pushes the tagged image to the private registry, and reads the built image's architecture back for verification.

The deploy runs from the burst box immediately after the push, through the builder's `then` hook. `CodeMySpec.Provisioning.Deploy` passes the already-built `CMS_IMAGE`, target architecture, app host, registry credentials, SSH key path, and secret key to the generated deploy script. That script pulls the image; it does not start another build. The deployment migrates against the new image before moving traffic, then checks health and swaps traffic. On a failed migration, health check, or swap, the previous version remains live. The first deploy has a separate bootstrap path because Kamal's host env file does not yet exist.

```text
project HEAD + Dockerfile
  -> Provisioning.Builder on target-architecture burst box
  -> private cms-registry on app server (image tagged with short commit SHA)
  -> Deploy.run on burst box -> migrate -> health check -> Kamal traffic swap
```

There is no GitHub Actions image-build gate and no GHCR pull in this flow. Do not restore a generated `.github/workflows/build.yml` or wait for one from a deploy script. See `lib/code_my_spec/provisioning/steps.ex`, `builder.ex`, `builder/remote.ex`, `registry.ex`, and `deploy.ex` for the executable contract.

## Dockerfile gotchas for Phoenix builds

These details apply to the Dockerfile built on the burst box and are retained from the retired CI image-build playbook:

1. **Create empty `envs/` placeholders** when Dotenvy or Varlock loaders require files during the image build, while production secrets arrive at runtime:

   ```dockerfile
   RUN mkdir -p envs && touch envs/.env envs/prod.env
   ```

2. **Retry `mix assets.deploy`** if esbuild or tailwind binary downloads intermittently fail, especially on ARM:

   ```dockerfile
   RUN for attempt in 1 2 3 4 5; do \
         mix assets.deploy && break; \
         [ "$attempt" = "5" ] && exit 1; \
         sleep $((attempt * 5)); \
       done
   ```

3. **Install Node only when needed.** If the app bundles an npm package through esbuild (for example `html-to-image`), install `nodejs npm` in the builder stage and run `npm install` in `assets/` before `mix assets.deploy`. The managed esbuild binary alone does not require this.

4. **Handle ARM for bundled non-Elixir binaries.** Match the target host architecture when downloading a CLI in the Dockerfile. Docker's `TARGETARCH` can select the right artifact:

   ```dockerfile
   ARG TARGETARCH
   RUN case "${TARGETARCH:-amd64}" in \
         amd64) ARCH=64-bit ;; \
         arm64) ARCH=arm64 ;; \
       esac && curl -sSL ".../tool_${ARCH}.tar.gz" | tar xz ...
   ```

## Health and migrations

The proxy's health path must answer without session, auth, CSRF, or database access. Put `/health` outside router pipelines and exclude it from `force_ssl`; otherwise the proxy's plain-HTTP probe may receive a redirect rather than a successful response. Migrations must be additive while the old container still serves traffic against the new schema.

## References

- [Kamal docs](https://kamal-deploy.org/)
- [kamal-proxy](https://github.com/basecamp/kamal-proxy)
- [Phoenix releases guide](https://hexdocs.pm/phoenix/releases.html)
