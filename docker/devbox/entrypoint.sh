#!/bin/bash
# devbox-init — bring up a working CodeMySpec project from nothing.
#
# Idempotent by design: /workspace is expected to be a mounted volume, so a
# restart must reuse the project generated on the first run rather than
# refusing to start (or, worse, regenerating over the user's work).
set -euo pipefail

APP_NAME="${APP_NAME:-my_app}"
APP_DIR="/workspace/${APP_NAME}"

# One port, said once.
#
# A generated app's runtime.exs defaults PORT to 4100 -- deliberately not
# Phoenix's 4000, because on a laptop 4000 is already CodeMySpec's own server.
# Inside this container nothing competes, and three other things assume 4000:
# the log line below, the port `Workspaces.Runner.Docker` publishes, and
# therefore every health check the server makes against the instance.
#
# Left to the default, the app listened on 4100 while Docker published 4000, so
# nothing answered on the host port and the workspace sat at "booting" forever
# -- while the app itself was up and its preview served perfectly, because
# cloudflared runs inside and reads the same runtime.exs the app does. The
# visitor's progress bar was the only thing that was wrong, which is the worst
# place for a mismatch to show up.
export PORT="${PORT:-4000}"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# --- postgres ---------------------------------------------------------------
log "Starting Postgres"
su postgres -c "pg_ctl -D ${PGDATA} -l /tmp/postgres.log -w start"

# The generated app connects as postgres/postgres on 127.0.0.1; the cluster
# was initdb'd with trust auth, so the password is cosmetic but must exist
# for the role to be usable if a project later switches to md5.
su postgres -c "psql -tAc \"ALTER USER postgres WITH PASSWORD 'postgres'\"" >/dev/null

# --- project ----------------------------------------------------------------
if [ ! -f "${APP_DIR}/mix.exs" ]; then
  log "Generating ${APP_NAME} with mix cms.new"
  mkdir -p /workspace
  cd /workspace
  # --install would run deps.get before we've set the DB config; do it
  # explicitly below so a failure is attributable.
  mix cms.new "${APP_NAME}" --no-install
else
  log "Reusing existing project at ${APP_DIR}"
fi

cd "${APP_DIR}"

log "Fetching dependencies"
mix deps.get

log "Setting up the database"
mix ecto.create
mix ecto.migrate

# --- identity ---------------------------------------------------------------
# Onboard the copy we just generated, when the host told us which copy it is.
#
# Without this the container comes up holding an application and nothing else:
# no .cms_harness.json, so nothing walks up to an identity, no working copy row
# for the person to see, and no preview address. It ran, and it belonged to
# nobody.
#
# The id is minted by the host before the container starts, because minting
# needs the server and the point of onboarding is that the copy already has an
# identity to be onboarded *as*.
#
# Absent, this is skipped rather than failed. A devbox started by hand for
# development has no host to have told it anything, and it should still come up.
if [ -n "${CMS_WORKING_COPY_ID:-}" ]; then
  log "Onboarding ${APP_NAME} as ${CMS_WORKING_COPY_ID}"
  # --server-url is what makes the tunnel a *result* of onboarding rather than
  # something that has to happen later. Without it `Preview.ensure` has nowhere
  # to ask, answers "no preview", and the app comes up with nothing to show —
  # silently, because no preview is a legitimate answer and looks identical to
  # never having asked.
  mix harness.onboard \
    --id "${CMS_WORKING_COPY_ID}" \
    ${CMS_DEPLOY_KEY:+--deploy-key "${CMS_DEPLOY_KEY}"} \
    ${CMS_SERVER_URL:+--server-url "${CMS_SERVER_URL}"} \
    || log "Onboarding did not complete; the app still runs, unowned"

  # `mix harness.onboard` comes from client_utils, which a generated app
  # depends on instead of CodeMySpec — so its flags are `--id`,
  # `--deploy-key`, `--server-url` and nothing about which project, and
  # `.cms_harness.json` comes out with `"project_id": null`. That is fatal
  # here in a way it never was on a laptop: `CmsHarness.Projects.
  # start_configured/0`'s sprite path (CMS_PROJECT_DIR at boot, which is the
  # only path this container has — nobody is sitting in it running a
  # session to fire the laptop path's hook) reads project_id straight off
  # this file with no network fallback, and refused outright —
  # `:no_project_id` — the one time this was actually exercised end to end
  # against a rebuilt image. The host already knows it: CMS_PROJECT_ID is
  # part of `Workspaces.instance_env/1`'s standard env, the same list
  # CMS_WORKING_COPY_ID above came from. Patched in rather than passed as a
  # flag the task does not have; merged rather than overwritten for the same
  # reason `HarnessConfig.write/2` merges everywhere else — onboarding above
  # already wrote the deploy key and preview address into this file, and a
  # fresh map would take both with it.
  if [ -n "${CMS_PROJECT_ID:-}" ] && [ -f "${APP_DIR}/.cms_harness.json" ]; then
    # `mix run -e`, not bare `elixir -e`: Jason is a compiled dependency of
    # this app, on the code path `mix` already knows how to find rather than
    # one this script would have to locate under `_build` by hand.
    #
    # Read through the environment rather than passed as script args — `mix
    # run -e` needs a `--` separator before extra argv reaches the script,
    # and CMS_HARNESS_CONFIG_PATH/CMS_PROJECT_ID are already exported into
    # this same process, which every child inherits for free.
    CMS_HARNESS_CONFIG_PATH="${APP_DIR}/.cms_harness.json" \
      mix run --no-start -e '
        path = System.fetch_env!("CMS_HARNESS_CONFIG_PATH")
        project_id = System.fetch_env!("CMS_PROJECT_ID")
        config = path |> File.read!() |> Jason.decode!()
        config |> Map.put("project_id", project_id) |> Jason.encode!(pretty: true) |> then(&File.write!(path, &1))
      '
  fi
else
  log "No working copy id given; starting un-onboarded"
fi

# --- harness ----------------------------------------------------------------
# `start`, not `server`: this is a plain mix release, and `start` is its
# launcher's foreground boot command. `server` is only a dev-time mix alias
# and the launcher rejects it outright. (The brew formula runs `cms start`
# under launchd for the same reason.)
#
# Backgrounded: the harness is a companion to the project, not a gate on it.
# If it dies the app must stay up so the user can still work.
#
# CMS_PROJECT_DIR is what makes it actually serve this project rather than
# come up and sit idle. `CmsHarness.Projects.start_configured/0` only picks a
# project two ways: this env var at boot (the sprite path) or a hook fired by
# an already-running dev session (the laptop path) — and nobody is sitting in
# this container running a session to fire that hook. Onboarding above writes
# `.cms_harness.json`, which gives the copy an identity, but identity alone
# was never enough to be served; that is `34e03128` one runner over. Found by
# booting a real container through `Runner.Docker` for the first time since
# the image build itself was fixed: it came up, the app answered, and the
# harness sat there logging nothing but "no machine-wide credential" forever
# — no join, no restore attempt, nothing for an agent to ever confirm against.
log "Starting the cms harness server on :4003"
CMS_PROJECT_DIR="${APP_DIR}" cms start &

# --- app --------------------------------------------------------------------
log "Starting ${APP_NAME} on :${PORT}"
exec mix phx.server
