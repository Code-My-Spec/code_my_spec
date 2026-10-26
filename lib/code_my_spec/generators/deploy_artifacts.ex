defmodule CodeMySpec.Generators.DeployArtifacts do
  @moduledoc """
  Writes the deploy artifacts a project needs before setup can deploy it.

  `DeployBoilerplate` says what is missing and why it matters; this puts it
  there. The split is deliberate — the audit runs against every project,
  including ones generated elsewhere, and must keep working when this module
  is not what produced the files.

  ## Where the content comes from

  `priv/knowledge/devops/hetzner-docker-deploy.md` — the stack this project
  actually deploys on. The image is built in CI and pushed to the project's registry, Kamal pulls
  it onto the host by commit SHA, and kamal-proxy terminates TLS and routes by
  hostname. Writing a plausible-looking Dockerfile from memory would produce a
  project that generates cleanly and fails on its first real deploy.

  ## Nothing here carries a secret

  The environment files are scaffolding: named `.enc.env` so the encrypted
  shape is established from the first commit, and containing no values. A
  plaintext `.env` trusted to `.gitignore` leaks on the first mistake.
  """

  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.Projects.Project

  @type result :: {:ok, [String.t()]} | {:error, term()}

  @doc """
  The OTP application name for a project — not the repository name.

  `module_name` underscored (e.g. `DevopsDrill` -> `devops_drill`). The slug
  fallback replaces hyphens: this is interpolated into a release name, a
  `_build/prod/rel/<app>` path and module names, none of which can carry one.
  """
  @spec otp_app_name(map()) :: String.t()
  def otp_app_name(%{module_name: name}) when is_binary(name) and name != "",
    do: Macro.underscore(name)

  def otp_app_name(project),
    do: project |> Project.slug() |> String.replace("-", "_")

  @doc """
  Write every missing artifact, leaving anything already present alone.

  Returns the paths written. Existing files are never overwritten: a project
  that has customised its Dockerfile has done so for a reason, and generation
  is not the moment to discover that.
  """
  @spec generate(ExecutionContexts.ExecutionContext.t(), keyword()) :: result()
  def generate(env, opts \\ []) do
    app = Keyword.get(opts, :app, "app")
    host = Keyword.get(opts, :host, "example.com")
    image = Keyword.get(opts, :image)
    registry = Keyword.get(opts, :registry)
    owner = Keyword.get(opts, :owner, "your-org")

    cond do
      is_nil(image) or is_nil(registry) or is_nil(opts[:kamal_image]) ->
        {:error, :registry_image_required}

      image != "#{Keyword.get(opts, :prod_registry) || registry}/#{opts[:kamal_image]}" ->
        {:error, :registry_image_mismatch}

      true ->
        generate_with_registry(env, opts, app, host, registry, owner, image)
    end
  end

  defp generate_with_registry(env, opts, app, host, registry, owner, image) do
    artifacts =
      files(
        app: app,
        host: host,
        registry: registry,
        owner: owner,
        image: image,
        kamal_image: Keyword.get(opts, :kamal_image),
        prod_registry: Keyword.get(opts, :prod_registry),
        uat_registry: Keyword.get(opts, :uat_registry),
        telemetry_host: Keyword.get(opts, :telemetry_host, "telemetry.#{host}")
      )

    artifacts
    |> Enum.reject(fn {path, _} -> present?(env, path) end)
    |> Enum.reduce_while({:ok, []}, fn {path, content}, {:ok, written} ->
      case ExecutionContexts.write_file(env, path, content) do
        :ok ->
          {:cont, {:ok, [path | written]}}

        {:ok, _} ->
          {:cont, {:ok, [path | written]}}

        # Reported, not crashed: name the file that could not be written.
        other ->
          {:halt, {:error, {path, other}}}
      end
    end)
    |> case do
      {:ok, written} ->
        written = Enum.reverse(written)

        # A non-executable script fails with :enoent, which reads as "never
        # written".
        for path <- written,
            String.starts_with?(path, "bin/") or String.contains?(path, "overlays/bin/") do
          ExecutionContexts.cmd(env, "chmod", ["+x", path])
        end

        {:ok, written}

      error ->
        error
    end
  end

  @doc """
  Every artifact this generator can write, as `{path, content}`.

  Options:

    * `:image` — the exact image reference. Comes from
      `CodeMySpec.Provisioning.Registry.image/2` and is required by
      `generate/2`.
    * `:kamal_image` — kamal's `image:`, a bare repository path (kamal reads
      the host from `registry.server`), where CI's `docker build -t` needs the
      full reference. Required by `generate/2`.
    * `:prod_registry` / `:uat_registry` — per-environment registry hosts,
      since two environments may sit on two boxes. Each defaults to
      `:registry`.
  """
  @spec files(keyword()) :: [{String.t(), String.t()}]
  def files(opts) do
    app = Keyword.fetch!(opts, :app)
    host = Keyword.fetch!(opts, :host)
    registry = Keyword.fetch!(opts, :registry)
    owner = Keyword.fetch!(opts, :owner)
    image = Keyword.get(opts, :image) || "#{registry}/#{owner}/#{app}"
    kamal_image = Keyword.get(opts, :kamal_image) || image
    prod_registry = Keyword.get(opts, :prod_registry) || registry
    uat_registry = Keyword.get(opts, :uat_registry) || registry
    telemetry_host = Keyword.get(opts, :telemetry_host) || "telemetry.#{host}"

    [
      {"Dockerfile", dockerfile(app)},
      {".github/workflows/build.yml", ci_workflow([prod_registry, uat_registry], kamal_image)},
      {"config/deploy.yml",
       kamal_config(app, kamal_image, host, "prod", prod_registry, telemetry_host)},
      {"config/deploy.uat.yml",
       kamal_config(app, kamal_image, "uat.#{host}", "uat", uat_registry, telemetry_host)},
      {".sops.yaml", sops_rules()},
      {"rel/overlays/bin/boot", boot_overlay(app)},
      {"rel/overlays/bin/migrate", migrate_overlay(app)},
      {"bin/deploy", deploy_script()},
      {"bin/backup", backup_script()},
      {"envs/prod.enc.env", env_scaffold("prod")},
      {"envs/uat.enc.env", env_scaffold("uat")},
      {"lib/#{app}_web/router.ex", router(app)},
      {"lib/#{app}_web/controllers/health_controller.ex", health_controller(app)},
      {"lib/#{app}/release.ex", release_module(app)},
      {"config/runtime.exs", runtime_config(app)}
    ]
  end

  defp present?(env, path) do
    match?({:ok, _}, ExecutionContexts.read_file(env, path))
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

    # A git-sourced mix dependency (phx.new's own default: heroicons via
    # github:) fetches over smart-http, which is a GET followed by a POST
    # negotiation — unlike the plain GET a health check or `curl` makes.
    # This image's bundled git/curl breaks that POST specifically over
    # HTTP/2 against GitHub, failing "could not read Username for
    # 'https://github.com'" / "expected flush after ref listing" — a
    # credential prompt and a corrupted pkt-line stream, neither a real
    # symptom of what actually happened. Confirmed live: a plain `curl` GET
    # to the same URL from the same box gets a clean 200, and forcing
    # HTTP/1.1 clones the same repo cleanly where HTTP/2 fails every time.
    # Global, not `-c http.version=...` on a single command, because Mix
    # shells out to bare `git fetch`/`git clone` itself and has no flag of
    # its own to carry the override through.
    RUN git config --global http.version HTTP/1.1

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

  # Multi-arch: the box may be ARM (Hetzner's cax range) or amd64, and the
  # wrong one fails at `docker run` with an error that names nothing useful.
  defp ci_workflow(registries, repository) do
    registry_hosts = registries |> Enum.uniq() |> Enum.map_join(", ", &~s("#{&1}"))

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
        strategy:
          matrix:
            registry: [#{registry_hosts}]

        steps:
          - uses: actions/checkout@v4

          - uses: docker/setup-qemu-action@v3
          - uses: docker/setup-buildx-action@v3

          - uses: docker/login-action@v3
            with:
              registry: ${{ matrix.registry }}
              username: ${{ secrets.CMS_REGISTRY_USERNAME }}
              password: ${{ secrets.CMS_REGISTRY_PASSWORD }}

          # Tagged by commit SHA, so what is running is traceable to a commit
          # rather than to whenever `latest` was last pushed.
          - uses: docker/build-push-action@v6
            with:
              context: .
              platforms: linux/amd64,linux/arm64
              push: true
              tags: |
                ${{ matrix.registry }}/#{repository}:${{ github.sha }}
                ${{ matrix.registry }}/#{repository}:latest
              cache-from: type=gha
              cache-to: type=gha,mode=max
    """
  end

  # One file per environment, so a UAT deploy cannot touch production's host.
  # `servers.web` is the environment's hostname: the DNS step points it at the
  # box before the deploy step runs.
  #
  # The ssh block is ERB, rendered by kamal at deploy time against
  # `CMS_SSH_KEY_PATH` (set by provisioning). `keys_only` stops kamal offering
  # every agent identity and hitting `MaxAuthTries`, then an interactive prompt
  # that dies with `Errno::ENOTTY`. Guarded so a human run keeps kamal's
  # defaults. See knowledge/infrastructure, "Generated deploy artifacts".
  defp kamal_ssh_block do
    """
    <% if ENV["CMS_SSH_KEY_PATH"] %>
    ssh:
      keys: ["<%= ENV["CMS_SSH_KEY_PATH"] %>"]
      keys_only: true
      log_level: debug
    <% end %>
    """
  end

  defp kamal_config(app, image, host, environment, registry, _telemetry_host) do
    service_name = "#{app}#{if environment == "prod", do: "", else: "-#{environment}"}"

    """
    # Kamal deploys #{environment} for #{app}.
    service: #{service_name}
    image: #{image}
    #{kamal_ssh_block()}
    servers:
      web:
        hosts:
          - #{host}
        options:
          network: db_net

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
      server: #{registry}
      username:
        - KAMAL_REGISTRY_USERNAME
      password:
        - KAMAL_REGISTRY_PASSWORD

    env:
      clear:
        APP_ENV: #{environment}
        PHX_HOST: #{host}
        # Names this deploy to the project's own telemetry collector, so
        # traces and logs land under the right ServiceName with no manual
        # config on Sam's part (criterion 1713/1855).
        OTEL_SERVICE_NAME: #{service_name}-web
        OTEL_EXPORTER_OTLP_ENDPOINT: http://cms-otel-collector:4318
        OTEL_EXPORTER_OTLP_PROTOCOL: http/protobuf
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

  # One recipient per environment: UAT's key cannot open production's secrets.
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

  # Shared by both overlays: each starts the release, whose `runtime.exs` reads
  # DATABASE_URL and SECRET_KEY_BASE. One function so the two cannot drift.
  # A missing file or key is named before sops runs, because sops reports an
  # absent key as "no identity matched any of the recipients".
  # See knowledge/infrastructure, "Generated deploy artifacts".
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

  # `exec` so the release is PID 1 and receives the container's stop signals.
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

  # `migrate_overlay/1` calls `<App>.Release.migrate` inside the release, where
  # there is no Mix to run `mix ecto.migrate`.
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

  # Two callers. `CodeMySpec.Provisioning.Deploy.run/3` calls `migrate <env>`,
  # health-checks, then `swap <env>`, with `CMS_IMAGE` naming the image it
  # already built and pushed, so that path never touches GitHub. A human runs
  # the "all" branch: push, wait for CI, migrate, swap.
  # See knowledge/infrastructure, "Generated deploy artifacts".
  defp deploy_script do
    """
    #!/usr/bin/env bash
    #
    #   bin/deploy [uat|prod]              — for a human: push, wait for CI,
    #                                         migrate, then swap.
    #   bin/deploy migrate|swap <uat|prod> — what CodeMySpec's own setup
    #                                         calls. It already built and
    #                                         pushed a specific image and
    #                                         drives health checking itself
    #                                         between the two phases, so
    #                                         neither is meant to run alone
    #                                         by hand.
    set -euo pipefail

    case "${1:-}" in
      migrate|swap)
        PHASE="$1"
        ENVIRONMENT="${2:?usage: bin/deploy $1 <uat|prod>}"
        ;;
      *)
        PHASE="all"
        ENVIRONMENT="${1:-uat}"
        ;;
    esac

    CONFIG="config/deploy.yml"
    [ "$ENVIRONMENT" = "uat" ] && CONFIG="config/deploy.uat.yml"

    # CMS_IMAGE names the exact image (registry/repo:tag) setup already built
    # and pushed. Building or pulling another one here would deploy a
    # different commit than the one setup verified. Without it — a human
    # running this by hand — the version is whatever HEAD names once CI has
    # published it.
    if [ -n "${CMS_IMAGE:-}" ]; then
      VERSION="${CMS_IMAGE##*:}"
    else
      VERSION="$(git rev-parse HEAD)"
    fi

    swap() {
      # `--skip-push`: by the time this runs, the image is already on the
      # registry — setup's own builder pushed it (the automated path) or
      # `wait for CI to publish it` already did (the human "all" path).
      # Without this flag, `kamal deploy` rebuilds and re-pushes the image
      # itself before pulling it back down, and that redundant push's
      # blob-existence check (verifying blobs the FIRST push already
      # uploaded) is a different code path in buildx's registry client than
      # uploading new content — one that ignores the daemon's
      # insecure-registries config and always assumes HTTPS. Confirmed live
      # against MarketMySpec: a self-hosted HTTP-only registry accepted the
      # first push fine and only failed on kamal's own redundant second one.
      kamal deploy --config-file "$CONFIG" --version "$VERSION" --skip-push
    }

    migrate() {
      # `-e`, so the migration carries the key instead of reading the host's
      # copy. `kamal app exec` loads env/roles/<role>.env from the host, and
      # kamal writes that only when it boots a container — so the migration
      # ran against the environment of the last successful boot. A rotated
      # SOPS_AGE_KEY deadlocked on it: the deploy re-encrypts to the new key,
      # the migration reads the old one off the host, and the deploy that
      # would replace the host's copy is the one that cannot finish.
      #
      # `--config-file`, not `--config` — kamal has no `--config` flag at
      # all, only `-c`/`--config-file`. Thor silently folded the unrecognised
      # `--config "$CONFIG"` into `app exec`'s own CMD positional, so runc
      # tried to exec the literal string "--config" as the container's
      # entrypoint. Confirmed live against MarketMySpec on kamal 2.11.0.
      #
      # A host with no successful deploy in its history has no env file at
      # all yet — kamal only ever writes one as a side effect of booting a
      # container. `CodeMySpec.Provisioning.Deploy.run/3` is what handles
      # that case (an explicit, logged "bootstrap" phase before retrying
      # migrate), not this script: `bin/deploy migrate` just fails here, the
      # same as any other migrate failure, and the caller decides what a
      # missing env file means.
      kamal app exec --config-file "$CONFIG" --version "$VERSION" -e "SOPS_AGE_KEY:${SOPS_AGE_KEY:-}" "bin/migrate"
    }

    case "$PHASE" in
      migrate)
        migrate
        ;;
      swap)
        swap
        ;;
      all)
        echo "deploying $VERSION to $ENVIRONMENT"

        git push origin HEAD

        echo "waiting for CI to publish the image for $VERSION"
        gh run watch --exit-status "$(gh run list --commit "$VERSION" --limit 1 --json databaseId --jq '.[0].databaseId')"

        migrate
        swap

        echo "deployed $VERSION to $ENVIRONMENT"
        ;;
    esac
    """
  end

  # Must stay byte-identical to the script `cms_new` generates
  # (`templates/deploy/backup_script.eex`). Used only for projects not
  # scaffolded by `mix cms.new` and by the spex harness.
  # See knowledge/infrastructure, "Generated deploy artifacts".
  defp backup_script do
    """
    #!/usr/bin/env bash
    # Database backups: dump to your own bucket, restore from it, and install the
    # nightly schedule.
    #
    #   bin/backup dump prod                    # dump now, upload, print the key
    #   bin/backup restore dumps/... scratch    # restore that key into a scratch DB
    #   bin/backup schedule prod                # install the nightly timer
    #   bin/backup list prod                    # what is actually in the bucket
    #
    # The dump goes straight from this host to the bucket and never passes through
    # the control plane — a production dump is exactly the kind of thing that is a
    # megabyte in staging and eighty gigabytes in production.
    #
    # Every subcommand prints `name=value` lines for the values a caller needs
    # (`key=`, `rows=`). One line-oriented convention keeps the contract small
    # enough to hold in your head and greppable from a shell when a run goes wrong.
    set -euo pipefail

    REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
    cd "$REPO_ROOT"

    # Global, not a function-local: the EXIT trap runs after the function has
    # returned, so a `local tmp` is out of scope by then and `set -u` turns a
    # successful dump into a non-zero exit. That failure is worse than it looks —
    # the caller reads the exit code, so a backup that worked reports as broken.
    TMPFILE=""
    cleanup() { [ -n "$TMPFILE" ] && rm -f "$TMPFILE"; return 0; }
    trap cleanup EXIT

    # The bucket, its credentials and the database URL come from the environment's
    # own encrypted env file — the same one the app boots with, so a backup cannot
    # silently target a different database than the one that is running.
    load_env() {
      local env_name="$1"
      local key_file="envs/${env_name}.age.key"
      local enc_file="envs/${env_name}.enc.env"

      # Already in the environment? Then there is nothing to decrypt.
      #
      # The caller that knows the bucket, the credentials and the connection string
      # hands them over (`Backups.script_env/1`), and it runs this on the
      # environment's own server — a box that has docker and curl and deliberately
      # nothing else. Insisting on decrypting anyway meant `sops: command not found`
      # on a host where sops was never going to be, for values that had already
      # arrived. The sibling generator's `load_secrets` has always worked this way.
      #
      # A person or a cron run supplies none of them and takes the path below.
      if [ -n "${DATABASE_URL:-}" ] && [ -n "${BACKUP_BUCKET:-}" ] && \\
         [ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ]; then
        : "${BACKUP_ENDPOINT:=https://fsn1.your-objectstorage.com}"
        : "${BACKUP_REGION:=fsn1}"
        return 0
      fi

      # SOPS_AGE_KEY first, the key file second — the same order bin/deploy uses,
      # and for the same reason.
      #
      # Setup holds the private half in its own secret store and deliberately never
      # writes it into the repository, so it hands it over in the environment
      # (`Backups.script_env/1` sets SOPS_AGE_KEY, and says so). This script only
      # ever looked for the file, so every setup-run backup died on "missing
      # envs/<env>.age.key" — a key that was present, passed correctly, and never
      # read. The message named a file nobody had promised to write, which reads
      # like the secrets step failed rather than like the two halves disagreeing.
      #
      # The file stays the fallback: a person running this by hand keeps it in
      # envs/<env>.age.key, and cron on the server has neither a caller nor a
      # terminal, so it needs a source of its own.
      if [ -z "${SOPS_AGE_KEY:-}" ]; then
        if [ ! -f "$key_file" ]; then
          echo "missing $key_file, and SOPS_AGE_KEY is not set — the backup needs this environment's age key" >&2
          exit 1
        fi

        export SOPS_AGE_KEY
        SOPS_AGE_KEY=$(cat "$key_file")
      fi

      if [ -z "${SOPS_AGE_KEY:-}" ]; then
        echo "ERROR: SOPS_AGE_KEY is empty; refusing to back up" >&2
        exit 1
      fi

      if [ ! -f "$enc_file" ]; then
        echo "missing $enc_file" >&2
        exit 1
      fi

      set -a
      # shellcheck disable=SC1090
      source <(sops --decrypt "$enc_file")
      set +a

      for var in DATABASE_URL BACKUP_BUCKET AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
        if [ -z "${!var:-}" ]; then
          echo "ERROR: $var is not set in $enc_file; refusing to continue" >&2
          exit 1
        fi
      done

      : "${BACKUP_ENDPOINT:=https://fsn1.your-objectstorage.com}"
      : "${BACKUP_REGION:=fsn1}"
    }

    # aws-cli is not assumed. Signing a single PUT/GET by hand is a dozen lines and
    # removes a dependency from every host that has to be able to restore — which,
    # on the day it matters, is a host you are building in a hurry.
    s3() {
      local method="$1" object="$2" file="$3"
      local url="${BACKUP_ENDPOINT}/${BACKUP_BUCKET}/${object}"

      if [ "$method" = "PUT" ]; then
        curl -sSf -X PUT --aws-sigv4 "aws:amz:${BACKUP_REGION}:s3" \\
          --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}" \\
          --data-binary "@${file}" "$url" >/dev/null
      else
        curl -sSf --aws-sigv4 "aws:amz:${BACKUP_REGION}:s3" \\
          --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}" \\
          -o "$file" "$url"
      fi
    }

    # Postgres tooling, from wherever it actually is.
    #
    # The environment's server runs docker and curl and nothing else — that is what
    # its image is for, and adding a postgres client by apt would put the one job
    # that has to work on the worst day behind a package mirror. The database
    # container already carries pg_dump and psql and already sits on the network
    # where cms-postgres resolves, so this borrows them.
    #
    # A host that does have the binaries uses them directly, so a laptop restore
    # still works with no docker at all.
    pg() {
      local bin="$1"; shift

      if command -v "$bin" >/dev/null 2>&1; then
        "$bin" "$@"
      else
        docker run --rm -i --network "${PG_NETWORK:-db_net}" "${PG_IMAGE:-pgvector/pgvector:pg18}" "$bin" "$@"
      fi
    }

    # ecto:// is the app's scheme, not libpq's.
    #
    # Ecto reads DATABASE_URL as ecto://user:pass@host/db and Phoenix apps write it
    # that way, so that is what setup puts in the encrypted env. pg_dump does not
    # know the scheme, and rather than refusing it falls back to reading the whole
    # string as a *database name* over a local socket:
    #
    #   pg_dump: error: connection to server on socket "/tmp/.s.PGSQL.5432"
    #   failed: FATAL: database "ecto://app:...@cms-post" does not exist
    #
    # Which names a socket nobody configured and a database nobody asked for, and
    # says nothing about the one character that is wrong. Translated here rather
    # than by changing what setup writes: the app's variable stays canonical and
    # the tool that needs libpq's spelling gets it.
    #
    # At the top level, because restoring needs the same translation as dumping and
    # a function defined inside cmd_dump would not exist until cmd_dump had run.
    libpq_url() {
      case "$1" in
        ecto://*) echo "postgresql://${1#ecto://}" ;;
        *) echo "$1" ;;
      esac
    }

    # Exact row count across every user table.
    #
    # `SUM(n_live_tup)` was the old answer and it is an estimate: pg_stat_user_tables
    # is populated by ANALYZE, so a table restored a second ago reports zero while
    # holding every row. A proof built on it says "that is a file, not a backup"
    # about a backup that is fine.
    #
    # COUNT(*) per table via query_to_xml, because the tables are not known ahead of
    # time and this is the one way to fold a dynamic count into a single scalar
    # without a procedural language.
    count_rows() {
      pg psql -tA "$1" -c "SELECT COALESCE(SUM(cnt), 0) FROM (
          SELECT (xpath('/row/c/text()',
                    query_to_xml(format('SELECT count(*) AS c FROM %I.%I', schemaname, tablename),
                                 false, true, '')))[1]::text::bigint AS cnt
          FROM pg_tables
          WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
        ) counts;" | tr -d "[:space:]"
    }

    cmd_dump() {
      local env_name="${1:-prod}"
      load_env "$env_name"

      local stamp key
      stamp=$(date -u +%Y%m%dT%H%M%SZ)
      key="dumps/${env_name}-${stamp}.sql.gz"
      TMPFILE=$(mktemp)

      # `--no-comments`: a restored comment on a shared, admin-installed
      # extension (COMMENT ON EXTENSION vector IS '...', which pg_dump
      # emits by default for anything that has one) needs to be that
      # extension's *owner* to replay — the restore role legitimately
      # never is, since vector is installed once, box-wide, into
      # template1, by the admin, and no single tenant's role should own a
      # resource every tenant shares. Comments are documentation, never
      # functionally significant to the app, so dropping them from the
      # dump entirely costs nothing a restore (verification or, someday,
      # a real one) needs to prove.
      pg pg_dump --no-owner --no-acl --no-comments "$(libpq_url "$DATABASE_URL")" | gzip -9 > "$TMPFILE"

      # A zero-byte dump uploads perfectly happily and restores into nothing.
      if [ ! -s "$TMPFILE" ]; then
        echo "pg_dump produced an empty file — refusing to upload it as a backup" >&2
        exit 1
      fi

      s3 PUT "$key" "$TMPFILE"

      echo "key=$key"
      echo "bytes=$(wc -c < "$TMPFILE" | tr -d ' ')"
      # What went in, so the restore has something to be equal to. A backup of an
      # empty database that restores empty is a correct backup; only a comparison
      # can say so.
      echo "rows=$(count_rows "$(libpq_url "$DATABASE_URL")")"
    }

    cmd_restore() {
      local key="${1:?usage: bin/backup restore <key> [target] [env]}"
      local target="${2:-scratch}"
      local env_name="${3:-prod}"
      load_env "$env_name"

      # Named explicitly rather than left to whatever `libpq_url ""` and an
      # empty `-h` do to psql's own error — a role provisioned before this
      # credential existed fails here with a clear reason instead of a
      # connection error that names no missing variable at all.
      : "${CMS_RESTORE_ADMIN_URL:?missing CMS_RESTORE_ADMIN_URL — re-run the server step to mint the restore-verification role}"

      TMPFILE=$(mktemp)

      s3 GET "$key" "$TMPFILE"

      # The target is dropped and recreated: restoring into a database that
      # already has rows would count someone else's data as proof.
      #
      # CMS_RESTORE_ADMIN_URL, not DATABASE_URL — CREATE/DROP DATABASE needs
      # a role with CREATEDB, which the app's own role deliberately never
      # carries (it authenticates every live request; a standing ability to
      # create databases is not a privilege a compromised request should
      # inherit). Setup mints and delivers a second, narrower role for
      # exactly this, alongside DATABASE_URL in the same encrypted env.
      local admin_url
      admin_url="$(libpq_url "$CMS_RESTORE_ADMIN_URL")"
      pg psql -v ON_ERROR_STOP=1 -q "$admin_url" -c "DROP DATABASE IF EXISTS \\"$target\\";"
      pg psql -v ON_ERROR_STOP=1 -q "$admin_url" -c "CREATE DATABASE \\"$target\\";"

      # The restore role, not the app's — it is what actually owns $target,
      # having just created it, so it is the only credential with database-
      # level CREATE there (needed for CREATE EXTENSION and every statement
      # the dump runs). Connecting as the app's own role instead — this
      # line's bug for one fix cycle — hit "permission denied to create
      # extension" for exactly this reason: DATABASE_URL's role owns
      # nothing in $target.
      local target_url
      target_url="$(libpq_url "${CMS_RESTORE_ADMIN_URL%/*}/${target}")"
      gunzip -c "$TMPFILE" | pg psql -v ON_ERROR_STOP=1 -q "$target_url" >/dev/null

      # Row count across every user table. The question this answers is "did the
      # data come back", and a restore that recreates empty tables answers it with
      # a zero — which is the failure worth catching.
      local rows
      rows=$(count_rows "$target_url")

      # Counted; the copy is production data with no further use.
      pg psql -v ON_ERROR_STOP=1 -q "$admin_url" -c "DROP DATABASE IF EXISTS \\"$target\\";"

      echo "rows=${rows:-0}"
      echo "target=$target"
    }

    cmd_schedule() {
      local env_name="${1:-prod}"

      # A systemd timer rather than cron: it survives reboots, records its own
      # last run, and `systemctl list-timers` answers "did it fire" without
      # anyone having to parse a log.
      local unit="cms-backup-${env_name}"

      sudo tee "/etc/systemd/system/${unit}.service" >/dev/null <<UNIT
    [Unit]
    Description=Nightly database backup (${env_name})

    [Service]
    Type=oneshot
    WorkingDirectory=${REPO_ROOT}
    ExecStart=${REPO_ROOT}/bin/backup dump ${env_name}
    UNIT

      sudo tee "/etc/systemd/system/${unit}.timer" >/dev/null <<UNIT
    [Unit]
    Description=Nightly database backup (${env_name})

    [Timer]
    OnCalendar=*-*-* 03:17:00
    Persistent=true

    [Install]
    WantedBy=timers.target
    UNIT

      sudo systemctl daemon-reload
      sudo systemctl enable --now "${unit}.timer"

      echo "unit=${unit}.timer"
    }

    cmd_list() {
      local env_name="${1:-prod}"
      load_env "$env_name"

      curl -sSf --aws-sigv4 "aws:amz:${BACKUP_REGION}:s3" \\
        --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}" \\
        "${BACKUP_ENDPOINT}/${BACKUP_BUCKET}?list-type=2&prefix=dumps/"
    }

    case "${1:-}" in
      dump)     shift; cmd_dump "$@" ;;
      restore)  shift; cmd_restore "$@" ;;
      schedule) shift; cmd_schedule "$@" ;;
      list)     shift; cmd_list "$@" ;;
      *)
        echo "usage: bin/backup {dump|restore|schedule|list} ..." >&2
        exit 1
        ;;
    esac
    """
  end

  # The proxy probes `/health` before moving traffic, so it answers without a
  # session, auth or database — hence no `:browser` pipeline.
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

  defp health_controller(app) do
    web = Macro.camelize(app) <> "Web"

    """
    defmodule #{web}.HealthController do
      use #{web}, :controller

      def show(conn, _params), do: Plug.Conn.send_resp(conn, 200, "ok")
    end
    """
  end

  # `force_ssl` must not redirect the proxy's probe: kamal-proxy asks over plain
  # HTTP, and a 301 reads as unhealthy. Config is keyed on the real OTP app
  # name; under any other key it configures nothing.
  defp runtime_config(app) do
    web = Macro.camelize(app) <> "Web.Endpoint"
    repo = Macro.camelize(app) <> ".Repo"

    """
    import Config

    if System.get_env("PHX_SERVER") do
      config :#{app}, #{web}, server: true
    end

    if config_env() == :prod do
      config :#{app}, #{web},
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

      config :#{app}, #{repo},
        url: System.fetch_env!("DATABASE_URL"),
        pool_size: String.to_integer(System.get_env("POOL_SIZE") || "2")
    end
    """
  end

  # Scaffolding, not secrets: the encrypted shape exists from the first commit
  # so nobody reaches for a plaintext `.env`.
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
