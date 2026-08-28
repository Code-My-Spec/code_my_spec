#!/bin/bash
# devbox-init — bring up a working CodeMySpec project from nothing.
#
# Idempotent by design: /workspace is expected to be a mounted volume, so a
# restart must reuse the project generated on the first run rather than
# refusing to start (or, worse, regenerating over the user's work).
set -euo pipefail

APP_NAME="${APP_NAME:-my_app}"
APP_DIR="/workspace/${APP_NAME}"

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
log "Starting the cms harness server on :4003"
cms start &

# --- app --------------------------------------------------------------------
log "Starting ${APP_NAME} on :4000"
exec mix phx.server
