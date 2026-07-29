#!/bin/bash
# devbox sprite — a disposable harness for one project, on centralized data.
#
# Differs from devbox-new-project in what it owns rather than in what it does:
# a sprite holds no database. The harness talks to the central Postgres, so
# stories, requirements, QA records and problems are the same rows the web UI
# renders. What lives here is a git working copy and nothing else, which is
# why destroying one mid-run costs nothing that isn't already pushed.
#
# It does not generate a project. Generation happens once, on the "new project"
# path; a sprite attaches to a repo that already exists.
set -euo pipefail

REPO_URL="${REPO_URL:?REPO_URL is required (https://github.com/owner/repo)}"
CMS_PROJECT_ID="${CMS_PROJECT_ID:?CMS_PROJECT_ID is required (CodeMySpec project UUID)}"

# The clone directory is chosen here, at runtime, and handed to the harness.
# It is deliberately not read back from the project row: that row is shared
# with every other checkout, so it cannot describe this container's disk.
APP_NAME="${APP_NAME:-$(basename "${REPO_URL}" .git)}"
APP_DIR="${APP_DIR:-/workspace/${APP_NAME}}"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# --- clone -------------------------------------------------------------------
# Idempotent: /workspace may be a mounted volume, and a restart should reuse
# the working copy rather than discard uncommitted work.
if [ -d "${APP_DIR}/.git" ]; then
  log "Reusing working copy at ${APP_DIR}"
else
  log "Cloning ${REPO_URL}"
  mkdir -p "$(dirname "${APP_DIR}")"
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    # The token is used for this clone only and rewritten away immediately, so
    # it never lands in .git/config on a volume that outlives the container.
    git clone "https://x-access-token:${GITHUB_TOKEN}@${REPO_URL#https://}" "${APP_DIR}" 2>&1 \
      | sed 's/x-access-token:[^@]*@/x-access-token:***@/g'
    git -C "${APP_DIR}" remote set-url origin "${REPO_URL}"
  else
    git clone "${REPO_URL}" "${APP_DIR}"
  fi
fi

# --- harness -----------------------------------------------------------------
# No migrations: the schema belongs to the server, which owns those rows. The
# sprite role has DML only, so an accidental migration fails loudly rather than
# altering a table the web app is serving from. (Migrator.run/0 no-ops on
# :dev_sprite for the same reason.)
log "Starting the harness for project ${CMS_PROJECT_ID}"
cd "${APP_DIR}"

export CMS_PROJECT_ID
export CMS_MCP_WORKING_DIR="${APP_DIR}"

exec /opt/cms/bin/code_my_spec_cli start
