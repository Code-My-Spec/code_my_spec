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
  alias CodeMySpec.Provisioning.Repository

  @type result :: {:ok, [String.t()]} | {:error, term()}

  @doc """
  The OTP application name for a project — not the repository name.

  `module_name` is where the app name already lives (e.g. `DevopsDrill`), and
  underscoring it is the conversion `mix` makes in the other direction. The
  fallback replaces hyphens rather than passing them through: `Repository.
  default_name/1` is the project name slugified for GitHub, where hyphens are
  correct and required, but an OTP app name cannot carry one — `DeployArtifacts`
  interpolates this into a release name, a `_build/prod/rel/<app>` path and a
  module name, and a hyphen breaks all three the same way it broke
  `defmodule Devops-drillWeb.Router`.
  """
  @spec otp_app_name(map()) :: String.t()
  def otp_app_name(%{module_name: name}) when is_binary(name) and name != "",
    do: Macro.underscore(name)

  def otp_app_name(project),
    do: project |> Repository.default_name() |> String.replace("-", "_")

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
      {:ok, written} ->
        written = Enum.reverse(written)

        # A script that is not executable fails with :enoent, which reads as
        # "the generator never wrote it" rather than "it wrote it without the
        # bit that lets it run".
        for path <- written, String.starts_with?(path, "bin/") or String.contains?(path, "overlays/bin/") do
          Environments.cmd(env, "chmod", ["+x", path])
        end

        {:ok, written}

      error ->
        error
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
      {"rel/overlays/bin/boot", boot_overlay(app)},
      {"rel/overlays/bin/migrate", migrate_overlay(app)},
      {"bin/deploy", deploy_script()},
      {"bin/backup", backup_script(app)},
      {"envs/prod.enc.env", env_scaffold("prod")},
      {"envs/uat.enc.env", env_scaffold("uat")},
      {"lib/#{app}_web/router.ex", router(app)},
      {"lib/#{app}/release.ex", release_module(app)},
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

    RUN apt-get update && apt-get install -y --no-install-recommends build-essential git curl \\
        && rm -rf /var/lib/apt/lists/*
    RUN mix local.hex --force && mix local.rebar --force

    # sops, fetched here so the runtime stage needs no download tooling of its
    # own. The container decrypts its own environment at boot, which is what
    # makes SOPS_AGE_KEY the only secret the deploy has to carry.
    #
    # `dpkg --print-architecture` prints amd64/arm64, which is exactly how sops
    # names its release assets — so this follows the image's own architecture
    # rather than assuming whichever one the deploy box happens to be.
    ARG SOPS_VERSION=3.9.4
    RUN curl -fsSL -o /usr/local/bin/sops \\
          "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.$(dpkg --print-architecture)" && \\
        chmod +x /usr/local/bin/sops && \\
        sops --version --disable-version-check

    ENV MIX_ENV=prod
    WORKDIR /build

    # Dependencies first, so a source change does not re-fetch them.
    COPY mix.exs mix.lock ./
    RUN mix deps.get --only prod && mix deps.compile

    COPY config config
    COPY priv priv
    COPY lib lib
    COPY assets assets

    # The encrypted environments travel inside the image, as release overlays.
    # The key does not: it arrives as SOPS_AGE_KEY at run time, so an image
    # somebody pulls without the key is ciphertext and nothing else.
    COPY envs rel/overlays/envs

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

    # sops, to decrypt that environment at boot. No download tooling in this
    # stage — the builder already fetched it for this image's architecture.
    COPY --from=builder /usr/local/bin/sops /usr/local/bin/sops

    # Not root. A container that runs as root turns a code-execution bug into a
    # host problem.
    RUN useradd --create-home --shell /usr/sbin/nologin #{app} && chown -R #{app}:#{app} /app
    USER #{app}

    ENV PHX_SERVER=true
    EXPOSE 4000

    # `bin/boot`, not `bin/#{app} start`. The release reads DATABASE_URL and
    # SECRET_KEY_BASE from its environment in runtime.exs, and nothing has put
    # them there yet — the image carries the ciphertext and the container
    # carries the key. Starting the release directly raises "environment
    # variable DATABASE_URL is missing", kamal waits out its health timeout,
    # and the deploy reports a failed traffic swap, naming the swap rather than
    # the thing that was wrong.
    CMD ["bin/boot"]
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
  #
  # `servers.web` is the environment's own hostname, the same value the proxy
  # block below uses. Generation happens before any server exists, so there is
  # no IP to write — but the DNS step points that name at the environment's box
  # before the deploy step runs, so kamal reaches the right machine by the time
  # it looks.
  #
  # It previously emitted `<%= #{}_host %>` — an EEx tag in a YAML file nothing
  # renders, handed to kamal verbatim by bin/deploy. Everything around it
  # interpolated correctly, so the file read as complete while naming a server
  # that could not exist.
  defp kamal_config(app, image, host, environment) do
    """
    # Kamal deploys #{environment} for #{app}.
    service: #{app}#{if environment == "prod", do: "", else: "-#{environment}"}
    image: #{image}

    servers:
      web:
        - #{host}

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

  # Both overlays need the same environment for the same reason: each starts
  # the release, and the release evaluates `runtime.exs`, which reads
  # DATABASE_URL and SECRET_KEY_BASE from its environment.
  #
  # This is one function because the two drifted apart once already. The
  # decryption was written for the serving path and `migrate` was left running
  # the release raw, so every migration died on "environment variable
  # DATABASE_URL is missing" — a deploy that could never complete, on every
  # project the generator produced.
  #
  # Both failures are named before sops is asked to do anything. An absent key
  # makes sops fail with "no identity matched any of the recipients", which
  # reads as the file being encrypted to somebody else rather than as nobody
  # having supplied a key.
  defp sops_preamble(command) do
    """
    set -eu

    cd -P -- "$(dirname -- "$0")/.."

    ENV_NAME="${APP_ENV:-prod}"
    ENV_FILE="envs/${ENV_NAME}.enc.env"

    if [ ! -f "$ENV_FILE" ]; then
      echo "$0: no $ENV_FILE in this image — setup encrypts one per environment" >&2
      echo "$0: APP_ENV=$ENV_NAME; the image holds: $(ls envs 2>/dev/null | tr '\\n' ' ')" >&2
      exit 1
    fi

    if [ -z "${SOPS_AGE_KEY:-}" ]; then
      echo "$0: SOPS_AGE_KEY is not set, so $ENV_FILE cannot be decrypted" >&2
      echo "$0: the deploy carries it to the host — see config/deploy*.yml env.secret" >&2
      exit 1
    fi

    exec sops exec-env "$ENV_FILE" "#{command}"
    """
  end

  # `exec` so the release is PID 1 and receives the signals a container stop
  # sends. Running it as a child would leave kamal's stop waiting for a process
  # that never hears it.
  defp boot_overlay(app) do
    """
    #!/bin/sh
    # Release overlay: turn the age key into an environment, then start the app.
    #
    # Setup encrypts each environment's secrets into `envs/<env>.enc.env` and
    # commits the ciphertext, and hands the container exactly one secret —
    # SOPS_AGE_KEY, that environment's own private key. Per-environment keys
    # mean UAT's cannot open production's, so being able to deploy UAT
    # discloses nothing about production.
    #{sops_preamble("./bin/#{app} start")}\
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
    #{sops_preamble("./bin/#{app} eval #{Macro.camelize(app)}.Release.migrate")}\
    """
  end

  # `migrate_overlay/1` calls `<App>.Release.migrate` inside the released
  # binary, where Mix does not exist to run `mix ecto.migrate`. Without this
  # module the call is to a function that was never generated, and the
  # failure surfaces as a migration crash on a real box (`d903556b`) rather
  # than as a missing file the readiness audit could have caught first.
  defp release_module(app) do
    module = Macro.camelize(app)

    """
    defmodule #{module}.Release do
      @moduledoc \"\"\"
      Used for executing DB release tasks when run in production without Mix
      installed.
      \"\"\"
      @app :#{app}

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

    # `-e`, so the migration carries the key instead of reading the host's copy.
    # `kamal app exec` loads env/roles/<role>.env from the host, and kamal writes
    # that only when it boots a container — so the migration ran against the
    # environment of the last successful boot. A rotated SOPS_AGE_KEY deadlocked
    # on it: the deploy re-encrypts to the new key, the migration reads the old
    # one off the host, and the deploy that would replace the host's copy is the
    # one that cannot finish.
    kamal app exec --config "$CONFIG" --version "$COMMIT" -e "SOPS_AGE_KEY:${SOPS_AGE_KEY:-}" "bin/migrate"
    kamal deploy --config "$CONFIG" --version "$COMMIT"

    echo "deployed $COMMIT to $ENVIRONMENT"
    """
  end

  # Three subcommands, because `Provisioning.Backups` drives this script rather
  # than a human: `dump` reports the key it wrote, `restore` reports how many
  # rows came back, and `schedule` installs the nightly run. The `key=`/`rows=`
  # lines are the contract — the step parses them, so prose alone would read as
  # a backup that silently proved nothing.
  #
  # It sources its own secrets when they are not already set, so the same script
  # works under systemd, under cron, and typed by hand during an incident — the
  # moment you least want to discover the backup tool only runs inside a unit
  # file.
  defp backup_script(app) do
    """
    #!/usr/bin/env bash
    #
    # Dump the database, put it in object storage, and prove a dump restores.
    #
    #   bin/backup dump <environment>
    #   bin/backup restore <key> <target-database>
    #   bin/backup schedule <environment>
    #
    # A dump nobody has restored is a file, not a backup — `restore` reads one
    # back into a scratch database and counts what came back, so the schedule
    # proves itself rather than trusting that the dump exists.
    set -euo pipefail

    APP=#{app}
    ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

    # ecto:// is the app's scheme, not libpq's. Ecto reads DATABASE_URL as
    # ecto://user:pass@host/db and that is what setup writes, but pg_dump and
    # psql do not know the scheme — and rather than refusing it, pg_dump reads
    # the whole string as a database name over a local socket:
    #
    #   pg_dump: error: connection to server on socket "/tmp/.s.PGSQL.5432"
    #   failed: FATAL: database "ecto://app:...@cms-post" does not exist
    #
    # naming a socket nobody configured and a database nobody asked for. The
    # app's variable stays canonical; the tools that need libpq's spelling get
    # it. Restoring needs this as much as dumping, which is what proves a dump.
    libpq_url() {
      case "$1" in
        ecto://*) echo "postgresql://${1#ecto://}" ;;
        *) echo "$1" ;;
      esac
    }

    # Under systemd these are already in the environment. Run by hand they are
    # not, and a backup script that only works inside its unit file is no use
    # in the incident where you need it.
    load_secrets() {
      local environment="${1:-prod}" file="$ROOT/envs/${1:-prod}.enc.env"
      [[ -n "${DATABASE_URL:-}" ]] && return 0
      [[ -f "$file" ]] || return 0
      set -a
      # shellcheck disable=SC1090
      if command -v sops >/dev/null 2>&1; then source <(sops -d "$file"); else source "$file"; fi
      set +a
    }

    cmd_dump() {
      local environment="${1:?usage: bin/backup dump <environment>}"
      load_secrets "$environment"

      local stamp key dump
      stamp="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
      # Under `dumps/` because that is the prefix the app lists to answer
      # "are backups still arriving?" — a dump outside it is invisible.
      key="dumps/$environment/$APP-$stamp.sql.gz"
      dump="$(mktemp -t "$APP-XXXXXX").sql.gz"

      pg_dump "$(libpq_url "${DATABASE_URL:?DATABASE_URL must be set}")" | gzip > "$dump"
      aws s3 cp "$dump" "s3://${BACKUP_BUCKET:?BACKUP_BUCKET must be set}/$key" \\
        --endpoint-url "${BACKUP_ENDPOINT:?BACKUP_ENDPOINT must be set}" >&2
      rm -f "$dump"

      # The step parses this line.
      echo "key=$key"
    }

    cmd_restore() {
      local key="${1:?usage: bin/backup restore <key> <target>}"
      local target="${2:?usage: bin/backup restore <key> <target>}"
      load_secrets "${BACKUP_ENVIRONMENT:-prod}"

      local dump
      dump="$(mktemp -t "$APP-restore-XXXXXX").sql.gz"
      aws s3 cp "s3://${BACKUP_BUCKET:?BACKUP_BUCKET must be set}/$key" "$dump" \\
        --endpoint-url "${BACKUP_ENDPOINT:?BACKUP_ENDPOINT must be set}" >&2

      # A scratch database, dropped first: restoring over a database that
      # already has rows would count those rows and pass on a broken dump.
      local admin
      admin="$(libpq_url "${DATABASE_URL%/*}")"
      psql "$admin/postgres" -c "DROP DATABASE IF EXISTS \\"$target\\"" >&2
      psql "$admin/postgres" -c "CREATE DATABASE \\"$target\\"" >&2
      gunzip -c "$dump" | psql "$admin/$target" >&2
      rm -f "$dump"

      # Rows across every user table — an empty restore is the failure this
      # whole subcommand exists to catch.
      local rows
      rows="$(psql "$admin/$target" -tAc "
        select coalesce(sum(n_live_tup), 0) from pg_stat_user_tables
      ")"
      psql "$admin/postgres" -c "DROP DATABASE IF EXISTS \\"$target\\"" >&2

      # The step parses this line.
      echo "rows=${rows:-0}"
    }

    cmd_schedule() {
      local environment="${1:?usage: bin/backup schedule <environment>}"
      local unit="$APP-backup-$environment"
      local line="0 4 * * * $APP $ROOT/bin/backup dump $environment >> /var/log/$APP-backup.log 2>&1"

      # A drop-in file, never `crontab -`. Rewriting the invoking user's
      # crontab is wrong twice over: setup does not necessarily run on the box
      # the schedule belongs to — during development it runs on a laptop, where
      # it installed a job pointing at a temp directory — and `crontab -` is
      # interactive enough to block forever when it cannot get at the spool,
      # which is a setup step that hangs rather than fails.
      #
      # Overwriting one file is also idempotent for free, where the read-filter-
      # write dance around `crontab -` is only idempotent if you get it right.
      if [[ -w /etc/cron.d ]]; then
        printf '%s\\n' "$line" > "/etc/cron.d/$unit"
        echo "installed /etc/cron.d/$unit"
      else
        # Not the target box. Leave the schedule in the project so the deploy
        # installs it, rather than silently scheduling nothing.
        mkdir -p "$ROOT/deploy"
        printf '%s\\n' "$line" > "$ROOT/deploy/$unit.cron"
        echo "wrote deploy/$unit.cron — the deploy installs it into /etc/cron.d"
      fi
      echo "scheduled nightly backup for $environment"
    }

    case "${1:-}" in
      dump)     shift; cmd_dump "$@" ;;
      restore)  shift; cmd_restore "$@" ;;
      schedule) shift; cmd_schedule "$@" ;;
      *) echo "usage: bin/backup {dump <environment>|restore <key> <target>|schedule <environment>}" >&2; exit 64 ;;
    esac
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
        #
        # `paths:`, not a bare list. `Plug.SSL.validate_exclude!/1` turns a
        # plain string into `{:hosts, [string]}` — so `exclude: ["/health"]`
        # excluded a *host* named "/health", matched nothing, and left the
        # probe being redirected exactly as if the option were absent.
        # `DeployBoilerplate` learned this from a deploy that stalled on
        # "target failed to become healthy" and tightened its audit to require
        # `paths:`; this generator kept emitting the form that audit rejects,
        # so every project it produced failed our own deploy-readiness check.
        #
        # The default hosts are restated because Plug drops them as soon as
        # `:exclude` is given at all.
        force_ssl: [
          rewrite_on: [:x_forwarded_proto],
          exclude: [hosts: ["localhost", "127.0.0.1"], paths: ["/health"]]
        ]

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
