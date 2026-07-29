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
