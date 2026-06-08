# CI Image Build: Multi-Arch → GHCR

How the Docker image a Kamal deploy pulls gets built. GitHub Actions builds `linux/amd64` and `linux/arm64` in parallel on **native runners** (no QEMU), pushes each by digest to GHCR, then a merge job assembles a multi-arch manifest tagged with the commit SHA. The deploy never builds locally — it waits for this workflow and pulls the SHA.

Companion: `hetzner-docker-deploy.md` (the deploy that consumes the image).

---

## Why this shape

- **Native ARM runner (`ubuntu-24.04-arm`)** instead of QEMU emulation — ARM Elixir builds under QEMU are ~10× slower and flaky. GitHub now offers free native ARM runners.
- **Push-by-digest + merge manifest** — each arch pushes an untagged image by digest; a final job stitches them into one manifest list. This is the buildx-recommended pattern for multi-arch from a matrix.
- **Tag = commit SHA** — Kamal deploys `--version=<sha>`, so the image tag and the deployed code are the same identifier. `latest` is also pushed for convenience.
- **Per-arch registry layer cache** (`buildcache-amd64` / `buildcache-arm64`, `mode=max`) — fast incremental builds without a self-hosted cache.

---

## The workflow

```yaml
# .github/workflows/build.yml
name: Build & Push image

on:
  push:
    branches: [master]
    paths-ignore: ["**.md", ".kamal/**", "config/deploy*.yml", "scripts/**"]
  workflow_dispatch: {}

permissions:
  contents: read
  packages: write

env:
  IMAGE: ghcr.io/code-my-spec/myapp

jobs:
  build:
    strategy:
      fail-fast: true
      matrix:
        include:
          - platform: linux/amd64
            runner: ubuntu-latest
          - platform: linux/arm64
            runner: ubuntu-24.04-arm        # native ARM, not QEMU
    runs-on: ${{ matrix.runner }}
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - id: build
        uses: docker/build-push-action@v6
        with:
          context: .
          platforms: ${{ matrix.platform }}
          outputs: type=image,name=${{ env.IMAGE }},push-by-digest=true,name-canonical=true,push=true
          cache-from: type=registry,ref=${{ env.IMAGE }}:buildcache-${{ matrix.platform == 'linux/amd64' && 'amd64' || 'arm64' }}
          cache-to:   type=registry,ref=${{ env.IMAGE }}:buildcache-${{ matrix.platform == 'linux/amd64' && 'amd64' || 'arm64' }},mode=max
      - name: Export digest
        run: |
          mkdir -p /tmp/digests
          digest="${{ steps.build.outputs.digest }}"
          touch "/tmp/digests/${digest#sha256:}"
      - uses: actions/upload-artifact@v4
        with:
          name: digests-${{ matrix.platform == 'linux/amd64' && 'amd64' || 'arm64' }}
          path: /tmp/digests/*
          if-no-files-found: error
          retention-days: 1

  merge:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
        with: { path: /tmp/digests, pattern: digests-*, merge-multiple: true }
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - name: Create manifest list and push
        working-directory: /tmp/digests
        run: |
          docker buildx imagetools create \
            -t ${{ env.IMAGE }}:${{ github.sha }} \
            -t ${{ env.IMAGE }}:latest \
            $(printf '${{ env.IMAGE }}@sha256:%s ' *)
      - run: docker buildx imagetools inspect ${{ env.IMAGE }}:${{ github.sha }}
```

Notes:
- **`paths-ignore`** skips rebuilds for doc/deploy-config-only changes (`scripts/`, `.kamal/`, `config/deploy*.yml`, `**.md`).
- **GHCR auth** uses the built-in `GITHUB_TOKEN` with `packages: write` — no PAT needed for pushing to `ghcr.io/<org>/<repo>`.
- **`fail-fast: true`** — if one arch fails, cancel the other; a half-built manifest is useless.

---

## Deploy gate

`scripts/deploy` ties the build to the deploy so you never ship a stale image:

```bash
git push origin "$BRANCH"
sleep 5
RUN_ID=$(gh run list --workflow=build.yml --branch="$BRANCH" --limit=1 --json databaseId --jq '.[0].databaseId')
gh run watch "$RUN_ID" --exit-status --interval 10
kamal deploy --skip-push --version="$(git rev-parse HEAD)"
```

`--skip-push` tells Kamal the image is already in the registry (CI put it there) — it pulls `IMAGE:<sha>` rather than building.

---

## Dockerfile gotchas (multi-arch / Phoenix)

These bite specifically on ARM and on the CI builder; fold into the standard Phoenix `Dockerfile`:

**1. Empty `envs/` placeholders** so Dotenvy/Varlock loaders don't crash when no file exists (all secrets arrive as container env, see `secrets-ssm.md`):
```dockerfile
RUN mkdir -p envs && touch envs/.env envs/prod.env
```

**2. Retry `mix assets.deploy`** — esbuild/tailwind binary downloads 504 intermittently on ARM runners:
```dockerfile
RUN for attempt in 1 2 3 4 5; do \
      mix assets.deploy && break; \
      [ "$attempt" = "5" ] && exit 1; \
      sleep $((attempt * 5)); \
    done
```

**3. `nodejs npm` in the builder stage** — only if the app bundles a JS package via esbuild (e.g. `html-to-image`). Add to the builder `apt-get install` and run `npm install` in `assets/` before `mix assets.deploy`. Most Phoenix apps don't need this (esbuild itself is a managed binary).

**4. `TARGETARCH`-conditional CLI installs** — when bundling a non-Elixir binary (e.g. Vale) in the runner stage, branch on arch:
```dockerfile
ARG TARGETARCH
RUN case "${TARGETARCH:-amd64}" in \
      amd64) ARCH=64-bit ;; \
      arm64) ARCH=arm64 ;; \
    esac && curl -sSL ".../tool_${ARCH}.tar.gz" | tar xz ...
```

---

## References
- [docker/build-push-action](https://github.com/docker/build-push-action)
- [Multi-platform images / push-by-digest](https://docs.docker.com/build/ci/github-actions/multi-platform/)
- [GitHub-hosted ARM runners](https://github.blog/changelog/2025-01-16-linux-arm64-hosted-runners-now-available-for-free-in-public-repositories-public-preview/)
- `kamal deploy --skip-push` — https://kamal-deploy.org/docs/commands/deploy/
