# Find eligible builder and runner images on Docker Hub. We use Debian
# instead of Alpine to avoid DNS resolution issues in production.
#
# https://hub.docker.com/_/elixir/tags
# https://hub.docker.com/_/debian/tags
#
# This file is based on these images:
#
#   - https://hub.docker.com/_/elixir/tags - for the build image
#   - https://hub.docker.com/_/debian/tags - for the release image
#   - https://pkgs.org/ - resource for finding needed packages
#   - Ex: elixir:1.19.5-otp-27-slim
#
ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=27
ARG DEBIAN_VERSION=bookworm-slim

ARG BUILDER_IMAGE="elixir:${ELIXIR_VERSION}-otp-${OTP_VERSION}-slim"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

# install build dependencies
RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git ca-certificates curl \
  && rm -rf /var/lib/apt/lists/*

# sops, fetched here so the runtime stage needs no download tooling of its
# own — same pattern (and version pin) `DeployArtifacts` generates for every
# other project's own Dockerfile. This server calls the `sops` binary
# directly (CodeMySpec.Provisioning.Sops) to manage a project's own
# envs/*.enc.env during provisioning; it is not something any release tool
# provides.
#
# `dpkg --print-architecture` prints amd64/arm64, which is exactly how sops
# names its release assets — so this follows the image's own architecture
# rather than assuming whichever one the build box happens to be.
ARG SOPS_VERSION=3.9.4
RUN curl -fsSL -o /usr/local/bin/sops \
      "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.$(dpkg --print-architecture)" \
  && chmod +x /usr/local/bin/sops \
  && sops --version --disable-version-check

# prepare build dir
WORKDIR /app

# install hex + rebar
RUN mix local.hex --force \
  && mix local.rebar --force

# set build ENV
ENV MIX_ENV="prod"

# install mix dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# copy compile-time config files before we compile dependencies
# to ensure any relevant config change will trigger the dependencies
# to be re-compiled.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

RUN mix assets.setup

COPY priv priv

COPY lib lib

# Compile the release
RUN mix compile

COPY assets assets

# compile assets
RUN mix assets.deploy

# Changes to config/runtime.exs don't require recompiling the code
COPY config/runtime.exs config/

COPY rel rel
RUN mix release code_my_spec

# start a new build stage so that the final image will only contain
# the compiled release and other runtime necessities
FROM ${RUNNER_IMAGE} AS final

RUN apt-get update \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses5 locales ca-certificates git openssh-client age \
  && rm -rf /var/lib/apt/lists/*

# `age-keygen` (from the `age` package above) mints and derives the
# per-environment keys CodeMySpec.Provisioning.Sops manages; `sops` itself
# edits/decrypts the encrypted env files those keys open. Both were missing
# entirely — this server had never actually run this path until a project's
# first real :server provisioning exercised it — and Sops.available?/0 reads
# either one missing as :sops_unavailable rather than a clearer error, since
# a mid-command failure is worse than refusing before starting.
COPY --from=builder /usr/local/bin/sops /usr/local/bin/sops

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR "/app"
RUN chown nobody /app

# set runner ENV
ENV MIX_ENV="prod"

# Only copy the final release from the build stage
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/code_my_spec ./

USER nobody

# If using an environment that doesn't automatically reap zombie processes, it is
# advised to add an init process such as tini via `apt-get install`
# above and adding an entrypoint. See https://github.com/krallin/tini for details
# ENTRYPOINT ["/tini", "--"]

CMD ["/app/bin/server"]
