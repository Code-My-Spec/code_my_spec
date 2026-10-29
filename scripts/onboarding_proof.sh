#!/usr/bin/env bash
# Unattended source-onboarding proof. Run from a checkout whose HEAD is to be tested.
# Usage: CMS_PROOF_EMAIL=... CMS_PROOF_PASSWORD_FILE=... \
#   bash scripts/onboarding_proof.sh TOKEN_FILE EMPTY_HOME [CLONE_SOURCE]
# The password file and token file stay outside EMPTY_HOME; their contents are
# never written to the clone or to a log. The runner needs read access to them.
set -euo pipefail

fail() { printf 'FAIL [%s]: %s\n' "$step" "$1" >&2; exit 1; }
step=preflight
[[ $# -ge 2 && $# -le 3 ]] || fail 'usage: onboarding_proof.sh TOKEN_FILE EMPTY_HOME [CLONE_SOURCE]'
token_file=$1
proof_home=$2
source=${3:-$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel)}
[[ -r $token_file && -s $token_file ]] || fail 'OAuth token file is missing or unreadable'
[[ -r ${CMS_PROOF_PASSWORD_FILE:-} && -s ${CMS_PROOF_PASSWORD_FILE:-} ]] || fail 'CMS_PROOF_PASSWORD_FILE is missing or unreadable'
[[ -n ${CMS_PROOF_EMAIL:-} ]] || fail 'CMS_PROOF_EMAIL is required'
[[ ! -e $proof_home || -d $proof_home ]] || fail 'EMPTY_HOME is not a directory'
mkdir -p "$proof_home"
if [[ ${CMS_PROOF_CHILD:-0} != 1 ]]; then
  [[ -z $(ls -A "$proof_home") ]] || fail 'EMPTY_HOME is not empty'
fi
proof_home=$(cd "$proof_home" && pwd -P)
claude_bin=${CMS_PROOF_CLAUDE_BIN:-$(command -v claude || true)}
[[ -x $claude_bin ]] || fail 'Claude Code executable is missing'
python_bin=${CMS_PROOF_PYTHON_BIN:-$(command -v python3 || true)}
[[ -x $python_bin ]] || fail 'Python 3 is required for the proof driver'
source_head=$(git -C "$source" rev-parse HEAD) || fail 'cannot read source commit'
# The clean child receives only the explicit proof configuration. Its PATH
# excludes the operator's asdf, mise, Homebrew and user-level installations.
if [[ ${CMS_PROOF_CHILD:-0} != 1 ]]; then
  exec env -i HOME="$proof_home" PATH='/usr/bin:/bin' \
    CMS_PROOF_CHILD=1 CMS_PROOF_CLAUDE_BIN="$claude_bin" CMS_PROOF_PYTHON_BIN="$python_bin" \
    CMS_PROOF_EMAIL="$CMS_PROOF_EMAIL" CMS_PROOF_PASSWORD_FILE="$CMS_PROOF_PASSWORD_FILE" \
    CMS_PROOF_SERVER_URL="${CMS_PROOF_SERVER_URL:-}" CMS_PROOF_TIMEOUT="${CMS_PROOF_TIMEOUT:-900}" \
    CMS_PROOF_SOURCE_HEAD="$source_head" CMS_SERVER_URL="${CMS_PROOF_SERVER_URL:-}" \
    /bin/bash "$0" "$token_file" "$proof_home" "$source"
fi

step=clone
clone=$HOME/checkout
mkdir -p "$HOME/logs"
git clone --recurse-submodules "$source" "$clone" >"$HOME/logs/clone.log" 2>&1 || fail 'clone failed (see logs/clone.log)'
[[ $(git -C "$clone" rev-parse HEAD) == "$CMS_PROOF_SOURCE_HEAD" ]] || fail 'clone did not contain the tested commit'
[[ ! -e $clone/.cms_harness.json ]] || fail 'clone already contains a harness credential'

step=toolchain
# Exercise the documented source entry with no operator toolchain on PATH.
# It must install Mix inside this empty HOME before onboarding.
cd "$clone"
CMS_HARNESS_PORT=4004 CMS_SERVER_URL="${CMS_PROOF_SERVER_URL:-}" bash scripts/start-harness >"$HOME/logs/harness.log" 2>&1 &
harness_pid=$!
cleanup() { kill "$harness_pid" 2>/dev/null || true; }
trap cleanup EXIT

step=device_code
deadline=$((SECONDS + CMS_PROOF_TIMEOUT))
user_code=
while (( SECONDS < deadline )); do
  line=$(grep -m1 'Approve this harness: open .* and enter ' "$HOME/logs/harness.log" || true)
  if [[ -n $line ]]; then
    user_code=${line##* enter }
    break
  fi
  if ! kill -0 "$harness_pid" 2>/dev/null; then
    if grep -q 'Elixir Mix is required' "$HOME/logs/harness.log"; then
      step=toolchain
      fail 'source entry could not install Elixir/Mix in the empty HOME (see logs/harness.log)'
    fi
    fail 'source harness exited before device code (see logs/harness.log)'
  fi
  sleep 2
done
[[ -n $user_code ]] || fail 'timed out before device code (see logs/harness.log)'

step=approve_device
server=${CMS_PROOF_SERVER_URL:-}
if [[ -z $server ]]; then
  server=$(sed -nE 's/^[[:space:]]*server_url:[[:space:]]*"?([^"#[:space:]]+)"?.*/\1/p' .code_my_spec/config.yml | head -1)
fi
[[ $server =~ ^https?://[^/]+ ]] || fail 'clone has no server_url and CMS_PROOF_SERVER_URL was not set'
export CMS_PROOF_SERVER_URL=$server CMS_PROOF_USER_CODE=$user_code
# Pass the password through stdin to Python, never through a process argument.
if ! "$python_bin" -c 'import json,os,sys,urllib.request; p=sys.stdin.read().strip(); body=json.dumps({"email":os.environ["CMS_PROOF_EMAIL"],"password":p,"user_code":os.environ["CMS_PROOF_USER_CODE"]}).encode(); req=urllib.request.Request(os.environ["CMS_PROOF_SERVER_URL"].rstrip("/")+"/dev/device-approvals",body,{"Content-Type":"application/json"}); response=urllib.request.urlopen(req,timeout=20); assert json.load(response)["approved"] is True' <"$CMS_PROOF_PASSWORD_FILE" >"$HOME/logs/approval.log" 2>&1; then
  fail 'dev server refused device approval (see logs/approval.log)'
fi
unset CMS_PROOF_USER_CODE

step=harness_ready
while (( SECONDS < deadline )); do
  if curl -fsS --max-time 2 http://localhost:4004/health >"$HOME/logs/health.json" 2>&1; then break; fi
  kill -0 "$harness_pid" 2>/dev/null || fail 'harness exited after approval (see logs/harness.log)'
  sleep 2
done
curl -fsS --max-time 2 http://localhost:4004/health >"$HOME/logs/health.json" 2>&1 || fail 'timed out waiting for harness health'
[[ -s .cms_harness.json ]] || fail 'harness is healthy but onboarding record is missing'
# The plugin's MCP header needs the ID issued during device onboarding.
CMS_HARNESS_ID=$("$python_bin" -c 'import json; record=json.load(open(".cms_harness.json")); print(record.get("working_copy_id") or record.get("harness_id") or "")')
[[ -n $CMS_HARNESS_ID ]] || fail 'onboarding record has no harness ID'
export CMS_HARNESS_ID

step=claude_init
# Read the token only at invocation time. No xtrace and no token-bearing log.
export CLAUDE_CODE_OAUTH_TOKEN=$(cat "$token_file")
[[ -n $CLAUDE_CODE_OAUTH_TOKEN ]] || fail 'OAuth token file is empty'
"$CMS_PROOF_CLAUDE_BIN" -p --plugin-dir "$clone/plugins/claude" --permission-mode auto \
  --output-format text '/codemyspec:init' >"$HOME/logs/init.log" 2>&1 || fail 'headless init failed (see logs/init.log)'
if grep -Eq 'No CodeMySpec service answered|only an .error. field|not found' "$HOME/logs/init.log"; then
  fail 'init did not reach the harness (see logs/init.log)'
fi

step=next_requirement
"$CMS_PROOF_CLAUDE_BIN" -p --plugin-dir "$clone/plugins/claude" --permission-mode auto \
  --output-format text 'Call get_next_requirement exactly once. If it offers work, claim that exact requirement with start_task. Report the requirement and task ID. Do no implementation work.' >"$HOME/logs/next_requirement.log" 2>&1 || fail 'get_next_requirement or start_task call failed (see logs/next_requirement.log)'
if ! grep -Eq 'requirement:|Offered:|fix_issue|ready_for_qa' "$HOME/logs/next_requirement.log"; then
  fail 'get_next_requirement returned no real work (see logs/next_requirement.log)'
fi
if ! grep -Eiq 'task[_ ]id|task [0-9a-f]{8}' "$HOME/logs/next_requirement.log"; then
  step=start_task
  fail 'no claimed task ID was reported (see logs/next_requirement.log)'
fi
unset CLAUDE_CODE_OAUTH_TOKEN
printf 'PASS: clone %s, device approval, harness health, init, and get_next_requirement\n' "$CMS_PROOF_SOURCE_HEAD"
