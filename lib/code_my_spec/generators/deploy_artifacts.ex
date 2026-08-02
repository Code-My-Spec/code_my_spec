defmodule CodeMySpec.Generators.DeployArtifacts do
  @moduledoc """
  Writes the deploy artifacts a project needs before setup can deploy it.

  `DeployBoilerplate` says what is missing and why it matters; this puts it
  there. The split is deliberate — the audit runs against every project,
  including ones generated elsewhere, and must keep working when this module
  is not what produced the files.

  ## Where the content comes from

  `priv/knowledge/devops/hetzner-docker-deploy.md` — the stack this project
  actually deploys on. The image is built in CI and pushed to GHCR, Kamal pulls
  it onto the host by commit SHA, and kamal-proxy terminates TLS and routes by
  hostname. Writing a plausible-looking Dockerfile from memory would produce a
  project that generates cleanly and fails on its first real deploy.

  ## Nothing here carries a secret

  The environment files are scaffolding: named `.enc.env` so the encrypted
  shape is established from the first commit, and containing no values. A
  generator that scaffolds a plaintext `.env` and trusts `.gitignore` leaks on
  the first mistake somebody makes with it (criterion 7979).
  """

  alias CodeMySpec.Environments

  @type result :: {:ok, [String.t()]} | {:error, term()}

  @doc """
  Write every missing artifact, leaving anything already present alone.

  Returns the paths written. Existing files are never overwritten: a project
  that has customised its Dockerfile has done so for a reason, and generation
  is not the moment to discover that.
  """
  @spec generate(Environments.Environment.t(), keyword()) :: result()
  def generate(env, opts \\ []) do
    app = Keyword.get(opts, :app, "app")
    host = Keyword.get(opts, :host, "example.com")
    registry = Keyword.get(opts, :registry, "ghcr.io")
    owner = Keyword.get(opts, :owner, "your-org")

    artifacts = files(app: app, host: host, registry: registry, owner: owner)

    artifacts
    |> Enum.reject(fn {path, _} -> present?(env, path) end)
    |> Enum.reduce_while({:ok, []}, fn {path, content}, {:ok, written} ->
      case Environments.write_file(env, path, content) do
        :ok ->
          {:cont, {:ok, [path | written]}}

        {:ok, _} ->
          {:cont, {:ok, [path | written]}}

        # Reported, not crashed. A write that fails partway leaves a project
        # holding some of what a deploy needs, and saying which file could not
        # be written is the difference between fixing a permission and
        # guessing at a half-generated tree.
        other ->
          {:halt, {:error, {path, other}}}
      end
    end)
    |> case do
      {:ok, written} -> {:ok, Enum.reverse(written)}
      error -> error
    end
  end

  @doc "Every artifact this generator can write, as `{path, content}`."
  @spec files(keyword()) :: [{String.t(), String.t()}]
  def files(opts) do
    app = Keyword.fetch!(opts, :app)
    host = Keyword.fetch!(opts, :host)
    registry = Keyword.fetch!(opts, :registry)
    owner = Keyword.fetch!(opts, :owner)
    image = "#{registry}/#{owner}/#{app}"

    [
      {"Dockerfile", dockerfile(app)},
      {".github/workflows/build.yml", ci_workflow(image)},
      {"config/deploy.yml", kamal_config(app, image, host, "prod")},
      {"config/deploy.uat.yml", kamal_config(app, image, "uat.#{host}", "uat")},
      {".sops.yaml", sops_rules()},
      {"rel/overlays/bin/migrate", migrate_overlay(app)},
      {"bin/deploy", deploy_script()},
      {"bin/backup", backup_script(app)},
      {"envs/prod.enc.env", env_scaffold("prod")},
      {"envs/uat.enc.env", env_scaffold("uat")},
      {"lib/#{app}_web/router.ex", router(app)},
      {"config/runtime.exs", runtime_config()}
    ]
  end

  defp present?(env, path) do
    match?({:ok, _}, Environments.read_file(env, path))
  end

  # Multi-stage, because the release does not need Elixir at runtime and a
  # smaller image is a smaller thing to pull onto every box on every deploy.
  defp dockerfile(app) do
    """
    # Build the release, then run it on a runtime with none of the build tools.
    FROM hexpm/elixir:1.17.3-erlang-27.1.2-debian-bookworm-20241111 AS builder

    RUN apt-get update && apt-get install -y --no-install-recommends build-essential git \\
        && rm -rf /var/lib/apt/lists/*
    RUN mix local.hex --force && mix local.rebar --force

    ENV MIX_ENV=prod
    WORKDIR /build

    # Dependencies first, so a source change does not re-fetch them.
    COPY mix.exs mix.lock ./
    RUN mix deps.get --only prod && mix deps.compile

    COPY config config
    COPY priv priv
    COPY lib lib
    COPY assets assets

    RUN mix assets.deploy
    RUN mix release

    FROM debian:bookworm-slim

    RUN apt-get update && apt-get install -y --no-install-recommends \\
          openssl libncurses6 locales ca-certificates \\
        && rm -rf /var/lib/apt/lists/*

    # The release was built against this locale; a mismatch corrupts anything
    # non-ASCII the app renders.
    RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
    ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

    WORKDIR /app
    COPY --from=builder /build/_build/prod/rel/#{app} ./

    # Not root. A container that runs as root turns a code-execution bug into a
    # host problem.
    RUN useradd --create-home --shell /usr/sbin/nologin #{app} && chown -R #{app}:#{app} /app
    USER #{app}

    ENV PHX_SERVER=true
    EXPOSE 4000

    CMD ["bin/#{app}", "start"]
    """
  end

  # Multi-arch, because the box may be ARM (Hetzner's cax range) or amd64 and
  # an image built for the wrong one fails at `docker run` with an error that
  # names nothing useful (criterion 7975).
  defp ci_workflow(image) do
    """
    name: build

    on:
      push:
        branches: [main]

    jobs:
      image:
        runs-on: ubuntu-latest
        permissions:
          contents: read
          packages: write

        steps:
          - uses: actions/checkout@v4

          - uses: docker/setup-qemu-action@v3
          - uses: docker/setup-buildx-action@v3

          - uses: docker/login-action@v3
            with:
              registry: ghcr.io
              username: ${{ github.actor }}
              password: ${{ secrets.GITHUB_TOKEN }}

          # Tagged by commit SHA, so what is running is traceable to a commit
          # rather than to whenever `latest` was last pushed.
          - uses: docker/build-push-action@v6
            with:
              context: .
              platforms: linux/amd64,linux/arm64
              push: true
              tags: |
                #{image}:${{ github.sha }}
                #{image}:latest
              cache-from: type=gha
              cache-to: type=gha,mode=max
    """
  end

  # One file per environment, because "each environment has its own deploy
  # configuration" is what keeps a UAT deploy from touching production's host
  # (criterion 7976).
  defp kamal_config(app, image, host, environment) do
    """
    # Kamal deploys #{environment} for #{app}.
    service: #{app}#{if environment == "prod", do: "", else: "-#{environment}"}
    image: #{image}

    servers:
      web:
        - <%= #{environment}_host %>

    proxy:
      ssl: true
      host: #{host}
      # The proxy probes this before moving traffic. It must answer without a
      # session, without auth and without the database (criterion 7977).
      healthcheck:
        path: /health
        interval: 3
        timeout: 5

    registry:
      server: ghcr.io
      username:
        - KAMAL_REGISTRY_USERNAME
      password:
        - KAMAL_REGISTRY_PASSWORD

    env:
      clear:
        APP_ENV: #{environment}
        PHX_HOST: #{host}
      secret:
        - SECRET_KEY_BASE
        - DATABASE_URL

    # Migrations run against the new image before traffic moves to it, so a
    # migration that fails leaves the old version serving.
    boot:
      limit: 1
      wait: 2
    """
  end

  # One recipient per environment: UAT's key cannot open production's secrets,
  # which is the whole point of having two.
  defp sops_rules do
    """
    # Written by CodeMySpec. One age recipient per environment — a key for one
    # environment cannot decrypt another's file, so a leaked UAT key does not
    # expose production.
    #
    # Fill in the public keys the provisioning run generated for this project;
    # the private halves stay on the box in /etc/<app>/age.key and are never
    # committed.
    creation_rules:
      - path_regex: envs/prod\\.enc\\.env$
        age: "<prod age recipient>"

      - path_regex: envs/uat\\.enc\\.env$
        age: "<uat age recipient>"
    """
  end

  defp migrate_overlay(app) do
    """
    #!/bin/sh
    # Run migrations inside the release, against the image about to serve.
    #
    # `eval` rather than `rpc`, because the app is not started yet — this runs
    # before traffic moves, so a failed migration leaves the previous version
    # serving rather than half-migrating under a live one.
    set -e

    exec bin/#{app} eval "#{Macro.camelize(app)}.Release.migrate"
    """
  end

  defp deploy_script do
    """
    #!/usr/bin/env bash
    #
    # Push, wait for CI to publish the image, migrate, then swap.
    #
    #   bin/deploy [uat|prod]
    #
    # In that order deliberately: the image has to exist before Kamal can pull
    # it, and the migration has to succeed before traffic moves. A deploy that
    # swaps first and migrates after leaves a new version talking to an old
    # schema.
    set -euo pipefail

    ENVIRONMENT="${1:-uat}"
    CONFIG="config/deploy.yml"
    [ "$ENVIRONMENT" = "uat" ] && CONFIG="config/deploy.uat.yml"

    COMMIT="$(git rev-parse HEAD)"
    echo "deploying $COMMIT to $ENVIRONMENT"

    git push origin HEAD

    echo "waiting for CI to publish the image for $COMMIT"
    gh run watch --exit-status "$(gh run list --commit "$COMMIT" --limit 1 --json databaseId --jq '.[0].databaseId')"

    kamal app exec --config "$CONFIG" --version "$COMMIT" "bin/migrate"
    kamal deploy --config "$CONFIG" --version "$COMMIT"

    echo "deployed $COMMIT to $ENVIRONMENT"
    """
  end

  defp backup_script(app) do
    """
    #!/usr/bin/env bash
    #
    # Dump the database and put it in object storage.
    #
    #   bin/backup
    #
    # A dump nobody has restored is a file, not a backup — `bin/restore` reads
    # one back into a scratch database, and the schedule proves itself that way
    # rather than by the dump merely existing.
    set -euo pipefail

    STAMP="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
    DUMP="/tmp/#{app}-${STAMP}.sql.gz"

    pg_dump "${DATABASE_URL:?DATABASE_URL must be set}" | gzip > "$DUMP"

    aws s3 cp "$DUMP" "s3://${BACKUP_BUCKET:?BACKUP_BUCKET must be set}/#{app}/${STAMP}.sql.gz" \\
      --endpoint-url "${BACKUP_ENDPOINT:?BACKUP_ENDPOINT must be set}"

    rm -f "$DUMP"
    echo "backed up #{app} at ${STAMP}"
    """
  end

  # The proxy probes `/health` before it moves traffic, so that route has to
  # answer without a session, without auth and without the database — anything
  # it depends on becomes a thing that can fail a deploy that would otherwise
  # have been fine (criterion 7977). Hence its own pipeline: not `:browser`,
  # which fetches a session and CSRF token it does not need.
  defp router(app) do
    web = Macro.camelize(app) <> "Web"

    """
    defmodule #{web}.Router do
      use #{web}, :router

      pipeline :browser do
        plug :accepts, ["html"]
        plug :fetch_session
        plug :fetch_live_flash
        plug :protect_from_forgery
        plug :put_secure_browser_headers
      end

      pipeline :api do
        plug :accepts, ["json"]
      end

      # Deliberately piped through nothing. The proxy asks this before traffic
      # moves; a session, an authentication check or a database round-trip here
      # turns an unrelated outage into a failed deploy.
      get "/health", #{web}.HealthController, :show

      scope "/", #{web} do
        pipe_through :browser

        get "/", PageController, :home
      end
    end
    """
  end

  # `force_ssl` must not redirect the proxy's probe. kamal-proxy asks over
  # plain HTTP from inside the network, and a 301 reads to it as unhealthy —
  # so the deploy never completes and the reason is a redirect nobody sees
  # (criterion 7978).
  defp runtime_config do
    """
    import Config

    if System.get_env("PHX_SERVER") do
      config :app, AppWeb.Endpoint, server: true
    end

    if config_env() == :prod do
      config :app, AppWeb.Endpoint,
        url: [host: System.get_env("PHX_HOST") || "example.com", port: 443, scheme: "https"],
        http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT") || "4000")],
        secret_key_base: System.fetch_env!("SECRET_KEY_BASE"),
        # `exclude` so the proxy's probe is not redirected. Without it the
        # health check gets a 301, reads as unhealthy, and the deploy stalls
        # with everything apparently fine.
        force_ssl: [rewrite_on: [:x_forwarded_proto], exclude: ["/health"]]

      config :app, App.Repo,
        url: System.fetch_env!("DATABASE_URL"),
        pool_size: String.to_integer(System.get_env("POOL_SIZE") || "2")
    end
    """
  end

  # Scaffolding, not secrets. The encrypted *shape* exists from the first
  # commit so nobody reaches for a plaintext `.env` to get started — that file
  # is what leaks when somebody force-adds it or edits `.gitignore`.
  defp env_scaffold(environment) do
    """
    # #{environment} secrets for this project, encrypted with sops.
    #
    # This file is scaffolding and holds no values yet. Add them with:
    #
    #     sops envs/#{environment}.enc.env
    #
    # which encrypts to the recipient named for #{environment} in .sops.yaml.
    # Do not create a plaintext .env alongside this: the point of committing
    # the encrypted shape from the start is that there is never a moment when
    # the easy path is an unencrypted file.
    """
  end
end
