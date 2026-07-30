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

while true; do
  attempt=$((attempt + 1))
  started=$(date +%s)
  log "starting agent (attempt ${attempt})"

  claude --permission-mode bypassPermissions -p "${PROMPT}" >>"${LOG}" 2>&1
  code=$?

  elapsed=$(( $(date +%s) - started ))

  if [ "${code}" -eq 0 ]; then
    log "agent exited cleanly after ${elapsed}s — the stop hook allowed the stop, so nothing is actionable. Done."
    exit 0
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
