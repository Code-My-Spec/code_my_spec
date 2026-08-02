#!/bin/bash
# Start a sprite drill. Host-side companion to sprite.sh (which runs inside).
#
# Eleven drills were started by hand before this existed, each one reconstructed
# from `docker inspect` of the last container. That is why they were not
# reproducible: the workspace volume, the bare repo inside it, the env set and
# the seccomp flag all had to be remembered, and forgetting the seccomp flag
# fails silently — QA falls back to curl-and-HTML and two unusable screens once
# passed a fully green suite.
#
#   ./docker/devbox/drill.sh                     # next drill number, empty repo
#   ./docker/devbox/drill.sh --label "QA for 989"
#   ./docker/devbox/drill.sh --seed /path/to/repo # start from existing code
#   ./docker/devbox/drill.sh --n 12 --reuse       # re-enter drill 12's workspace
#   ./docker/devbox/drill.sh --no-agent           # harness only, drive it yourself
#
# Defaults target the local E2E stack (:4102 + code_my_spec_e2e), which is
# where drills have always run. Override with CMS_SERVER_URL / CMS_PROJECT_ID /
# CMS_DEPLOY_KEY.
set -euo pipefail

cd "$(dirname "$0")/../.."

: "${COLIMA_HOME:=/Volumes/X10 Pro/colima-devbox}"
export COLIMA_HOME
docker context use colima-devbox >/dev/null 2>&1 || true

IMAGE="${IMAGE:-codemyspec/sprite:latest}"
APP="${APP:-e2e_todo}"
CMS_SERVER_URL="${CMS_SERVER_URL:-http://host.docker.internal:4102}"
CMS_PROJECT_ID="${CMS_PROJECT_ID:-dfb8779b-8bda-4cc7-bea8-5e13a990448b}"
AGENT_HOME_VOLUME="${AGENT_HOME_VOLUME:-cms-agent-home-v2}"

LABEL=""
SEED=""
N=""
REUSE=0
WITH_AGENT=1

while [ $# -gt 0 ]; do
  case "$1" in
    --label) LABEL="$2"; shift 2 ;;
    --seed)  SEED="$2";  shift 2 ;;
    --n)     N="$2";     shift 2 ;;
    --reuse) REUSE=1;    shift ;;
    --no-agent) WITH_AGENT=0; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }

# --- preflight ---------------------------------------------------------------
# Each of these has cost a drill. Checking them takes a second; discovering them
# forty minutes into a run does not.

docker image inspect "$IMAGE" >/dev/null 2>&1 \
  || die "image $IMAGE not found — build it first (see docker/devbox/Dockerfile header)"

docker volume inspect "$AGENT_HOME_VOLUME" >/dev/null 2>&1 \
  || die "agent home volume $AGENT_HOME_VOLUME missing — the drill has no Claude credential"

# The harness is reached from inside the container, but if it is down the drill
# starts, scans, and gets refused on every push.
server_probe="${CMS_SERVER_URL/host.docker.internal/127.0.0.1}"
curl -sS -o /dev/null --max-time 5 "$server_probe" \
  || die "no server answering at $server_probe — start it before drilling"

[ -n "${CMS_DEPLOY_KEY:-}" ] || die "CMS_DEPLOY_KEY is required (project deploy key for $CMS_PROJECT_ID)"

# A second sprite on the same project fights the first for the lease.
running="$(docker ps --filter "ancestor=$IMAGE" --format '{{.Names}}')"
[ -z "$running" ] || die "already running: $running — stop it first (docker stop $running)"

# --- pick the drill number ---------------------------------------------------
if [ -z "$N" ]; then
  last="$(docker volume ls --format '{{.Name}}' \
    | sed -n 's/^drill-ws\([0-9]*\)$/\1/p' | sort -n | tail -1)"
  N=$(( ${last:-1} + 1 ))
fi

VOLUME="drill-ws${N}"
NAME="cms-drill${N}"
LABEL="${LABEL:-drill ${N}}"

# --- workspace ---------------------------------------------------------------
# The sprite clones from a bare repo inside its own volume rather than from
# GitHub, so a drill leaves nothing behind and needs no token. An *empty* bare
# repo is not a mistake — sprite.sh treats a clone with no commits as the
# generation path, which is what a from-scratch drill exercises.
if [ "$REUSE" = "1" ]; then
  docker volume inspect "$VOLUME" >/dev/null 2>&1 || die "$VOLUME does not exist to reuse"
  log "Reusing $VOLUME"
else
  docker volume inspect "$VOLUME" >/dev/null 2>&1 \
    && die "$VOLUME already exists — pass --reuse, or --n for a fresh number"

  log "Creating $VOLUME with a bare ${APP}.git"
  docker volume create "$VOLUME" >/dev/null
  docker run --rm -v "$VOLUME:/w" --entrypoint sh alpine/git -c "
    set -e
    mkdir -p /w/.origin
    git init --bare -q /w/.origin/${APP}.git
  "

  if [ -n "$SEED" ]; then
    [ -d "$SEED/.git" ] || die "--seed $SEED is not a git repository"
    log "Seeding from $SEED"
    docker run --rm -v "$VOLUME:/w" -v "$SEED:/seed:ro" --entrypoint sh alpine/git -c "
      set -e
      git clone -q --bare /seed /tmp/seed.git
      git --git-dir=/tmp/seed.git push -q --mirror /w/.origin/${APP}.git
    "
  fi
fi

# --- run ---------------------------------------------------------------------
# seccomp=unconfined is for browser QA only: Chrome's sandbox needs user
# namespaces the default profile blocks, and vibium has no --no-sandbox escape.
# Without it QA silently degrades to curl-and-HTML.
log "Starting $NAME on $IMAGE"
docker run -d --name "$NAME" \
  --security-opt seccomp=unconfined \
  -e CMS_LIGHT_HARNESS=1 \
  -e CMS_SERVER_URL="$CMS_SERVER_URL" \
  -e CMS_DEPLOY_KEY="$CMS_DEPLOY_KEY" \
  -e CMS_PROJECT_ID="$CMS_PROJECT_ID" \
  -e REPO_URL="file:///workspace/.origin/${APP}.git" \
  -e APP_DIR="/workspace/${APP}" \
  -e CMS_HARNESS_LABEL="$LABEL" \
  -v "${AGENT_HOME_VOLUME}:/home/agent/.claude" \
  -v "${VOLUME}:/workspace" \
  --entrypoint /usr/local/bin/devbox-sprite \
  "$IMAGE" >/dev/null

# --- agent -------------------------------------------------------------------
# The container runs the harness only; devbox-agent is the supervised loop that
# actually works the graph. Starting one without the other gives a sprite that
# scans a directory forever and looks healthy doing it — which is exactly what
# drill 11 was still doing seventeen hours after its agent finished.
if [ "$WITH_AGENT" = "1" ]; then
  log "Waiting for the harness to accept a manifest"
  for _ in $(seq 1 30); do
    docker logs "$NAME" 2>&1 | grep -q "accepted the manifest" && break
    sleep 2
  done

  docker logs "$NAME" 2>&1 | grep -q "accepted the manifest" \
    || die "harness never accepted a manifest — check: docker logs $NAME"

  log "Starting the agent"
  docker exec -d -u agent \
    -e MIX_HOME=/home/agent/.mix \
    -e APP_DIR="/workspace/${APP}" \
    -e MCP_TOOL_TIMEOUT="${MCP_TOOL_TIMEOUT:-180000}" \
    -e MCP_TOOL_IDLE_TIMEOUT="${MCP_TOOL_IDLE_TIMEOUT:-180000}" \
    -e AGENT_HANG_TIMEOUT="${AGENT_HANG_TIMEOUT:-420}" \
    -w "/workspace/${APP}" \
    "$NAME" /usr/local/bin/devbox-agent
fi

cat <<EOF

  drill    ${N}
  name     ${NAME}
  volume   ${VOLUME}
  label    ${LABEL}
  server   ${CMS_SERVER_URL}
  project  ${CMS_PROJECT_ID}
  agent    $([ "$WITH_AGENT" = "1" ] && echo "running" || echo "not started (--no-agent)")

  follow   docker logs -f ${NAME}
  agent    docker exec ${NAME} tail -f /tmp/agent.log
  shell    docker exec -it -u agent -e MIX_HOME=/home/agent/.mix ${NAME} bash
  stop     docker stop ${NAME}

EOF
