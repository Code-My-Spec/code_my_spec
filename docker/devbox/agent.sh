#!/bin/bash
# Keeps one agent alive on this sprite.
#
# `claude -p` runs a turn and exits. On a desk that is fine: the human sees the
# error and presses up-arrow. Unattended there is nobody to press anything, so a
# single transient upstream failure — a 529, a dropped connection, a timeout —
# ends the run permanently, hours before the work is done. That is not a
# hypothetical: the first clean-room run on this image died to `API Error: 529
# Overloaded` during its opening survey, having changed nothing.
#
# The loop condition is the interesting part. It is NOT "run N times": the stop
# hook already decides when there is more to do. It blocks the stop while any
# requirement is actionable, which keeps the agent working inside a single
# invocation, so a *clean* exit means the harness let it go — nothing left to
# block on. A non-zero exit means the agent was cut off with work outstanding,
# and that is the only case worth retrying.
#
# So: exit 0 ends the run, anything else is a transient to back off from. The
# consecutive-failure cap is what stops a genuinely broken sprite (bad
# credentials, harness down, no plugin) from retrying until someone notices the
# bill.
set -uo pipefail

PROMPT="${AGENT_PROMPT:-Work the CodeMySpec requirement graph for this project until there is nothing actionable left. Loop: call get_next_requirement, then start_task on what it returns, do exactly what the task prompt says, and repeat. Do not ask for confirmation between requirements — decide and proceed.}"

LOG="${AGENT_LOG:-/tmp/agent.log}"
MAX_FAILURES="${AGENT_MAX_FAILURES:-6}"
# Capped exponential backoff. A 529 is a capacity signal, so retrying hard makes
# it worse for everyone including us; a few minutes is the right order.
BACKOFF=15
BACKOFF_CAP=300

fails=0
attempt=0

log() { printf '\n\033[1;35m[agent-supervisor] %s\033[0m\n' "$*" | tee -a "${LOG}"; }

# A sprite is disposable — sprite.sh says so in its own header, on the grounds
# that destroying one "costs nothing that isn't already pushed". That only holds
# if something pushes. The last run ended with 92 modified files and an agent
# politely asking whether it should commit; unattended, nobody answers, and two
# hours of work lives exactly as long as the container does.
#
# So the supervisor commits on a clean exit. Deliberately not on a failed one:
# a run that was cut off mid-requirement is a working copy in an unknown state,
# and committing that would push half-written code over a good branch.
commit_and_push() {
  cd "${APP_DIR:-$PWD}" || return 0
  git rev-parse --git-dir >/dev/null 2>&1 || { log "not a git repo — nothing to commit"; return 0; }

  if [ -z "$(git status --porcelain)" ]; then
    log "working copy is clean — nothing to commit"
    return 0
  fi

  git config user.name "CodeMySpec Agent"
  git config user.email "noreply@codemyspec.com"
  git add -A
  git commit -q -m "Agent run $(git rev-parse --short HEAD 2>/dev/null || echo initial)

Committed by the sprite supervisor on a clean exit — the stop hook allowed the
stop, so the harness considered nothing further actionable." \
    || { log "commit failed"; return 0; }

  log "committed $(git rev-parse --short HEAD)"

  # Push is best-effort and never fatal: a sprite that committed locally has
  # already saved the work from container disposal, which is the point. The
  # token is scrubbed from any output because git echoes the remote back on
  # failure.
  if [ -n "${GITHUB_TOKEN:-}" ] && [ -n "${REPO_URL:-}" ]; then
    git push -q "https://x-access-token:${GITHUB_TOKEN}@${REPO_URL#https://}" HEAD 2>&1 \
      | sed 's/x-access-token:[^@]*@/x-access-token:***@/g' \
      && log "pushed to ${REPO_URL}" \
      || log "push failed — work is committed locally but not pushed"
  else
    log "no GITHUB_TOKEN/REPO_URL — committed locally, not pushed"
  fi
}

# --- the stop hook has to actually reach the harness ---------------------------
# This loop's exit condition is "a clean exit means the stop hook allowed the
# stop". That sentence is only true if the stop hook can reach the harness. When
# it cannot, curl fails, Claude Code treats an unreachable hook as a hook with no
# opinion, and every stop is allowed — so the supervisor commits and reports
# success on the first turn, having gated nothing.
#
# That is not a hypothetical either. A full drill ran this way: the plugin posted
# to 4003, the harness listened on 4004, and the run was declared clean. Nothing
# in the log said otherwise, because there is nothing to say — the failure is
# silence.
#
# So: probe once, up front, and refuse to run rather than produce a green result
# that means nothing. A sprite that will not start is a page; a sprite that
# rubber-stamps its own work is a lie that takes a day to find.
hook_port() {
  python3 - <<'PY' 2>/dev/null || true
import json, pathlib, re, collections

roots = []
try:
    installed = json.loads(
        pathlib.Path("/home/agent/.claude/plugins/installed_plugins.json").read_text()
    )
    for entries in installed.get("plugins", {}).values():
        for entry in entries:
            if entry.get("installPath"):
                roots.append(pathlib.Path(entry["installPath"]))
except Exception:
    pass

ports = collections.Counter()
for root in roots:
    hooks = root / "hooks" / "hooks.json"
    if hooks.exists():
        ports.update(re.findall(r"localhost:(\d+)", hooks.read_text()))

if ports:
    print(ports.most_common(1)[0][0])
PY
}

PORT="$(hook_port)"

if [ -z "${PORT}" ]; then
  log "FATAL: no hook port found in the installed plugin. Either the plugin is not"
  log "       installed or its hooks.json changed shape. Without hooks the stop hook"
  log "       cannot gate, so a clean exit would prove nothing. Refusing to start."
  exit 78
fi

# Any HTTP response means something is listening and routing. A connection
# refusal is the failure being guarded against.
if curl -sS -o /dev/null -m 10 "http://localhost:${PORT}/api/hooks/session_start" \
     -X POST -H 'Content-Type: application/json' -d '{}' 2>/dev/null; then
  log "hooks reach the harness on ${PORT}"
else
  log "FATAL: nothing is answering hooks on localhost:${PORT}, which is where the"
  log "       installed plugin posts them. The stop hook would fail open and every"
  log "       stop would be allowed, so this run would report success without the"
  log "       harness ever gating it. Refusing to start."
  log "       Fix: set CMS_HARNESS_PORT=${PORT} on the sprite and restart it."
  exit 78
fi

while true; do
  attempt=$((attempt + 1))
  started=$(date +%s)

  # Where this attempt's output begins. The auth check below has to look at
  # THIS attempt only: the log outlives a supervisor, so scanning the whole
  # file lets a previous run's "OAuth session expired" abort a healthy one that
  # has only just started. Seen immediately — the first supervisor's failures
  # were still in the file when the next one came up after the login was fixed.
  offset=$(( $(wc -c <"${LOG}" 2>/dev/null || echo 0) + 1 ))

  log "starting agent (attempt ${attempt})"

  claude --permission-mode bypassPermissions -p "${PROMPT}" >>"${LOG}" 2>&1
  code=$?

  elapsed=$(( $(date +%s) - started ))

  if [ "${code}" -eq 0 ]; then
    log "agent exited cleanly after ${elapsed}s — the stop hook allowed the stop, so nothing is actionable. Done."
    commit_and_push
    exit 0
  fi

  # Some failures are not worth a single retry, let alone six. An expired login
  # is the clearest: it fails in about a second, it fails identically every
  # time, and no amount of backoff fixes it — only a human re-authenticating
  # does. Retrying burns roughly twelve minutes to arrive at the same answer,
  # with the real cause buried under supervisor noise.
  #
  # Checked against the tail rather than the exit code because Claude Code exits
  # 1 for everything; the message is the only thing that distinguishes "nobody
  # is logged in" from "the API was busy".
  this_attempt=$(tail -c "+${offset}" "${LOG}" 2>/dev/null || true)

  if printf '%s' "${this_attempt}" \
       | grep -qiE "OAuth session expired|Failed to authenticate|Invalid API key|not logged in"; then
    log "the agent is not authenticated — this needs a human to log in, and retrying cannot fix it. Stopping."
    printf '%s\n' "${this_attempt}" | tail -5 >&2
    exit 2
  fi

  # A turn that ran for a while before dying was doing real work; the failure
  # that ended it is unrelated to the ones before it. Only *consecutive* quick
  # failures suggest the sprite itself is broken.
  if [ "${elapsed}" -ge 120 ]; then
    fails=0
    BACKOFF=15
  else
    fails=$((fails + 1))
  fi

  if [ "${fails}" -ge "${MAX_FAILURES}" ]; then
    log "agent failed ${fails} times in a row without making progress (last exit ${code}). Giving up — this is a broken sprite, not a busy API. Last output:"
    tail -20 "${LOG}" >&2
    exit 1
  fi

  log "agent exited ${code} after ${elapsed}s; retrying in ${BACKOFF}s"
  sleep "${BACKOFF}"
  BACKOFF=$(( BACKOFF * 2 ))
  [ "${BACKOFF}" -gt "${BACKOFF_CAP}" ] && BACKOFF="${BACKOFF_CAP}"
done
