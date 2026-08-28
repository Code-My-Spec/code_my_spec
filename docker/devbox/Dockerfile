# CodeMySpec devbox — a container that boots straight into a working
# harness-native Phoenix project.
#
# This is NOT the production server image (see the Dockerfile at the repo
# root for that). This one is a development environment: Elixir, Postgres,
# the `cms.new` generator, and the `cms` harness server, so a user gets a
# running project without installing anything but Docker.
#
# Build (BuildKit named contexts avoid vendoring cms_new into this repo):
#
#   docker build -f docker/devbox/Dockerfile \
#     --build-context cms_new=/abs/path/to/cms_new \
#     --build-context cms_harness=/abs/path/to/cms_harness \
#     --build-context cms_scan=/abs/path/to/cms_scan \
#     -t codemyspec/devbox .
#
# Absolute paths for the contexts. A relative one is resolved against the build
# context root, which inside a git worktree is the worktree — so `../cms_new`
# finds nothing and the build fails somewhere much later than the mistake.
#
# Run (note the host port): a CodeMySpec developer almost certainly has
# something on 4000/4003/4004 already — the dev server, cli_demo and dev_cli
# bind those. The container's own ports are unchanged; only the host side is
# remapped, so pick anything free.
#
#   docker run --rm -p 4010:4000 \
#     -e APP_NAME=my_app \
#     -v "$HOME/.claude:/root/.claude" \
#     codemyspec/devbox
#
# Only the app port is published. `cms` binds 127.0.0.1 inside the container
# (config/config.exs), so publishing :4003 would map a port nothing answers
# on. That is the right default and not worth working around here: the agent
# runs INSIDE the container, where loopback reaches the harness fine.
# Exposing the harness to the host would mean binding it to 0.0.0.0, which
# is a real security decision about a service that holds project
# credentials — make it deliberately, not as a side effect of packaging.
#
#   docker exec -it <container> bash   # then run `claude` in /workspace/<app>
#
# The image is deliberately agentless: it mounts the user's own Claude Code
# credentials rather than brokering model access.
#
# --- sprite mode ---------------------------------------------------------
# Built with `--build-arg CMS_RELEASE_ENV=dev_sprite` (tag it separately), a
# sprite clones an existing repo and serves MCP against the central Postgres.
# It has no database of its own, so there is nothing to mount and nothing to
# back up:
#
#   docker run -d --name sprite \
#     -e REPO_URL=https://github.com/owner/repo \
#     -e CMS_PROJECT_ID=<project uuid> \
#     -e CMS_DB_HOST=host.docker.internal \
#     -e CMS_DB_NAME=code_my_spec_dev \
#     -e CMS_DB_USER=cms_sprite -e CMS_DB_PASSWORD=... \
#     -e GITHUB_TOKEN=... \
#     --security-opt seccomp=unconfined \
#     --entrypoint /usr/local/bin/devbox-sprite \
#     codemyspec/sprite
#
# seccomp=unconfined is required for browser QA and only for that. Chrome's
# sandbox needs user namespaces that Docker's default profile blocks, and
# vibium exposes no --no-sandbox option to work around it. Without the flag
# every QA session silently falls back to curl-and-HTML — which is how two
# unusable screens once passed a fully green suite.
#
# The agent must also run as the non-root `agent` user:
#   docker exec -u agent -e MIX_HOME=/home/agent/.mix ... claude ...
#
# MCP is on 127.0.0.1:4003 *inside* the container, same as the desktop
# harness — reach it with `docker exec`, or from the agent that runs in there.

ARG ELIXIR_IMAGE=hexpm/elixir:1.20.2-erlang-29.0.4-debian-trixie-20260713-slim

# =============================================================================
# Stage 1 — build the cms harness release for Linux
# =============================================================================
# The release workflow publishes darwin and windows tarballs; Linux targets
# were only just added to its matrix, so there is nothing to download yet.
# Building here is not a workaround: `mix release` is built natively per
# platform anyway (no cross-compile), so this is the same build CI runs, and
# a multi-stage copy keeps the source out of the final image.
FROM ${ELIXIR_IMAGE} AS cms-builder

# Rust: prod_cli pulls ortex/tokenizers, whose NIFs compile from source when
# no precompiled artifact matches this platform.
# Go: the standalone cms-mcp-relay stdio<->HTTP bridge that `mix release`'s
# copy_mcp_relay step drops into the release bin/.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       build-essential ca-certificates cmake curl git golang-go pkg-config \
  && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal
ENV PATH="/root/.cargo/bin:${PATH}"

# Which harness this image carries.
#
#   prod_cli   — the desktop harness: SQLite in ~/.codemyspec, local-first.
#   dev_sprite — a sprite: the same code against the central Postgres.
#
# It is a build arg rather than a runtime flag because the adapter is a
# compile-time decision — DocEmbedding derives its column types from
# `Application.compile_env(:code_my_spec, :adapter)`, so one binary cannot
# serve both. Two tags, one Dockerfile.
ARG CMS_RELEASE_ENV=prod_cli
ENV MIX_ENV=${CMS_RELEASE_ENV}
WORKDIR /src

RUN mix local.hex --force && mix local.rebar --force

COPY . /src

RUN cd relay && go build -trimpath -ldflags "-s -w" -o cms-mcp-relay .

RUN mix deps.get \
  && mix compile \
  && mix release code_my_spec_cli --path /opt/cms

# =============================================================================
# Stage 1b — the light harness
#
# A second, much smaller release. The light harness owns the disk and nothing
# else: it watches a working copy, scans it, and ships the conclusions to the
# server, which owns the database. So this stage has no Rust and no Go — no
# NIFs to build and no relay to link, because the relay it uses is the one the
# stage above already produced.
#
# cms_scan is copied as a *sibling* of cms_harness rather than into it: the
# dependency is `{:cms_scan, path: "../cms_scan"}`, so the layout on disk is
# part of the contract. Flattening them here would fail at deps.get with a
# message about a missing path, several minutes into a build.
FROM ${ELIXIR_IMAGE} AS harness-builder

# Rust, because the harness embeds. Inference is local so file content never
# crosses the wire, and that means Ortex — whose NIF crate compiles from source
# when no precompiled artifact matches the platform. This stage started without
# Rust, on the reasoning that the harness runs no analyzers of its own; adding
# embeddings changed that.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       build-essential ca-certificates cmake curl git pkg-config \
  && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal
ENV PATH="/root/.cargo/bin:${PATH}"

ENV MIX_ENV=prod
WORKDIR /src/cms_harness

RUN mix local.hex --force && mix local.rebar --force

COPY --from=cms_scan . /src/cms_scan
COPY --from=cms_harness . /src/cms_harness

# A named build context ignores this repo's .dockerignore, so whatever is in
# those working copies comes along — including a `_build` and `deps` compiled on
# the host. Beam files built by macOS in a Linux image fail in ways that read as
# anything but "wrong architecture", so they are removed rather than trusted.
RUN rm -rf /src/cms_harness/_build /src/cms_harness/deps \
           /src/cms_scan/_build /src/cms_scan/deps

RUN mix deps.get \
  && mix compile \
  && mix release --path /opt/cms_harness

# =============================================================================
# Stage 2 — the devbox itself
# =============================================================================
FROM ${ELIXIR_IMAGE}

# Postgres major version must match what the apt repo ships for trixie;
# pinning the client and server together keeps pg_ctl/initdb consistent.
ARG POSTGRES_VERSION=17

ENV LANG=C.UTF-8 \
    MIX_HOME=/root/.mix \
    HEX_HOME=/root/.hex \
    PGDATA=/var/lib/postgresql/data \
    PGUSER=postgres \
    PGPASSWORD=postgres \
    PGHOST=127.0.0.1

# inotify-tools is required for Phoenix live reload to work inside the
# container; without it the file watcher silently no-ops and code changes
# never reach the browser.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       build-essential \
       ca-certificates \
       curl \
       git \
       gnupg \
       inotify-tools \
       openssl \
       postgresql-${POSTGRES_VERSION} \
       postgresql-client-${POSTGRES_VERSION} \
       procps \
  && rm -rf /var/lib/apt/lists/*

# cloudflared, because a generated app carries its own preview tunnel and runs
# it in its own supervision tree — `ClientUtils.CloudflareTunnel`. Without the
# binary the app boots, warns "cloudflared not found in PATH — tunnel disabled",
# and serves nothing at the address onboarding just provisioned for it. That
# degrades gracefully, which is right, and is also exactly why it is easy to
# miss: everything else reports success.
#
# The static binary rather than Cloudflare's apt repository: one file, no
# signing key to rotate, and the architecture is whatever the image is being
# built for rather than whatever the builder happens to be.
ARG TARGETARCH
RUN curl -fsSL -o /usr/local/bin/cloudflared \
      "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${TARGETARCH}" \
  && chmod 0755 /usr/local/bin/cloudflared \
  && cloudflared --version

# Node is needed by the asset pipeline (esbuild/tailwind install their own
# binaries, but npm is still the escape hatch for anything a project adds).
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
  && apt-get install -y --no-install-recommends nodejs \
  && rm -rf /var/lib/apt/lists/*

# Claude Code. The image ships the client but no credentials — mount the
# user's own ~/.claude at run time. This is the local-development path: using
# one person's subscription to serve other people would be a licensing
# problem, so the hosted path needs an API key or Managed Agents instead.
RUN npm install -g @anthropic-ai/claude-code \
  && npm cache clean --force

# Vibium plus a browser for it to drive.
#
# The CodeMySpec plugin declares a `vibium` MCP server, so without this the
# agent has browser tools listed and none of them work. Every QA session ends up
# curl-and-HTML — no click, no keystroke, no viewport.
#
# That is not a theoretical gap. On the first full run it meant every control on
# the two main screens rendered with no class attribute at all — browser-default
# sizing against the 44px the specs commit to — and a completely green suite was
# compatible with both screens being unusable by thumb, because nothing in the
# project asserts on a class or a size. curl cannot see that. A browser can.
#
# Vibium depends only on `ws` and drives the browser over WebDriver, so it needs
# both chromium and chromedriver — the driver is not optional, and without it
# vibium fails at launch with "chromedriver not found" rather than at install.
# A few hundred MB, which is the price of QA that can see.
RUN apt-get update \
  && apt-get install -y --no-install-recommends chromium chromium-driver \
  && rm -rf /var/lib/apt/lists/* \
  && npm install -g vibium \
  && npm cache clean --force

# Containers have no user namespace for chromium's sandbox to use, so it aborts
# on startup unless told not to try. Set here rather than passed per-call so a
# tool that shells out to the browser does not have to know.

ENV CHROME_PATH=/usr/bin/chromium

# Claude Code keeps its state in two places: credentials and sessions under
# ~/.claude/, and its config at ~/.claude.json — a sibling of that directory,
# not a child. Mounting a volume at ~/.claude therefore persists the login and
# loses the config, and the next container starts with
# "Claude configuration file not found".
#
# Symlinking the config into the directory means one mount covers both. Created
# in the image so it survives the mount, and writing through a dangling symlink
# creates the target, so an empty volume still works on first run.
RUN ln -sf /root/.claude/claude.json /root/.claude.json

# A user for the agent to run as.
#
# Claude Code's bypassPermissions mode refuses to start under root — and that is
# the only mode that works unattended, because every other one eventually needs
# a prompt answered and there is nobody to answer it. Running with a hand-kept
# --allowedTools list instead is worse than it sounds: anything not named is
# denied silently, and the agent cannot tell "I lack permission" from "this
# environment is broken". One run was spent reporting that the sandbox denied
# `mix` when mix was fine.
#
# The container itself stays root — the entrypoint starts Postgres and the
# harness, which want it. Only the agent drops privileges, via
# `docker exec -u agent`.
RUN useradd --create-home --shell /bin/bash agent \
  && ln -sf /home/agent/.claude/claude.json /home/agent/.claude.json \
  && mkdir -p /workspace \
  && chown -R agent:agent /workspace /home/agent

# Point vibium's expected binaries at the system ones.
#
# Its postinstall downloads Chrome for Testing, and on arm64 it fetches x86_64
# builds that cannot execute here at all. That surfaced as "chromedriver not
# found" and then "timeout waiting for chromedriver" — never as a word about
# architecture — so the apt chromium above is the real browser and these are
# the paths vibium insists on looking in.
#
# Symlinks rather than deleting the cache: vibium checks for a versioned
# directory before it will launch anything.
#
# The destination is named explicitly. `cp -a src dst/` when dst does not exist
# copies src's *contents* under that name, which silently produced
# .cache/chrome-for-testing instead of .cache/vibium/chrome-for-testing — and
# succeeded, so no fallback fired and the build passed.
RUN set -eu; \
    D="$(dirname "$(find /root/.cache/vibium -name chromedriver | head -1)")"; \
    ln -sf /usr/bin/chromium "$D/chrome"; \
    ln -sf /usr/bin/chromedriver "$D/chromedriver"; \
    mkdir -p /home/agent/.cache; \
    cp -a /root/.cache/vibium /home/agent/.cache/vibium; \
    chown -R agent:agent /home/agent/.cache

ENV PATH="/usr/lib/postgresql/${POSTGRES_VERSION}/bin:${PATH}"

RUN mix local.hex --force && mix local.rebar --force

# --- cms.new generator -------------------------------------------------------
# Built from source rather than fetched: cms_new is not published to hex, and
# vendoring a copy into this repo would create a second source of truth for
# the templates.
COPY --from=cms_new . /opt/cms_new
RUN cd /opt/cms_new \
  && MIX_ENV=prod mix archive.build -o /tmp/cms_new.ez \
  && mix archive.install /tmp/cms_new.ez --force \
  && rm -rf /tmp/cms_new.ez _build

# --- cms harness server ------------------------------------------------------
# Copied from the builder stage: only the assembled release lands here, not
# the source or the Rust/Go toolchains that produced it.
COPY --from=cms-builder /opt/cms /opt/cms

# Both harnesses ship. Which one serves a project is a runtime choice
# (CMS_LIGHT_HARNESS=1 in sprite.sh), not a separate image — a drill that can
# only be run by rebuilding is a drill that does not get run.
COPY --from=harness-builder /opt/cms_harness /opt/cms_harness

# A wrapper rather than a symlink, matching the brew formula: the release
# launcher resolves RELEASE_ROOT relative to its own path, and a symlink in
# /usr/local/bin would make it resolve there instead of /opt/cms.
RUN printf '#!/bin/bash\nexec /opt/cms/bin/code_my_spec_cli "$@"\n' > /usr/local/bin/cms \
  && chmod 0755 /usr/local/bin/cms

# The Claude Code plugin's MCP config spawns `cms-mcp-relay` by bare name, so it
# has to be on PATH — the brew formula symlinks it for the same reason. Without
# this the plugin loads its hooks and skills but no MCP tools, which looks like
# the harness being down rather than a missing symlink.
#
# A symlink is right here where a wrapper was right for `cms`: the relay is a
# static Go binary that resolves nothing relative to its own path.
RUN ln -sf /opt/cms/bin/cms-mcp-relay /usr/local/bin/cms-mcp-relay

# --- postgres cluster --------------------------------------------------------
# Initialised at build time so the first boot isn't paying for initdb. Trust
# auth on loopback only: this is a single-user dev container, and the
# alternative is baking a password users would have to discover.
RUN mkdir -p "$PGDATA" /var/run/postgresql \
  && chown -R postgres:postgres "$PGDATA" /var/run/postgresql \
  && su postgres -c "initdb -D $PGDATA --auth-local=trust --auth-host=trust" \
  # 'localhost' rather than '127.0.0.1': phx.new's generated dev.exs uses
  # hostname "localhost", which can resolve to ::1 first. Binding only the
  # IPv4 loopback makes ecto.create fail with a connection refused that looks
  # like Postgres never started.
  && echo "listen_addresses = 'localhost'" >> "$PGDATA/postgresql.conf"

COPY docker/devbox/entrypoint.sh /usr/local/bin/devbox-init
COPY docker/devbox/new-project.sh /usr/local/bin/devbox-new-project
COPY docker/devbox/sprite.sh /usr/local/bin/devbox-sprite
COPY docker/devbox/agent.sh /usr/local/bin/devbox-agent
RUN chmod 0755 /usr/local/bin/devbox-init /usr/local/bin/devbox-new-project \
      /usr/local/bin/devbox-sprite /usr/local/bin/devbox-agent

WORKDIR /workspace

# Only the app. The harness is loopback-only inside the container by design
# (see the header), so declaring 4003 here would advertise a port that never
# answers from outside.
EXPOSE 4000

ENV APP_NAME=my_app

ENTRYPOINT ["/usr/local/bin/devbox-init"]
