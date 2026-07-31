#!/bin/bash
# devbox sprite — a disposable harness for one project, on centralized data.
#
# Differs from devbox-new-project in what it owns rather than in what it does:
# a sprite holds no database. The harness talks to the central Postgres, so
# stories, requirements, QA records and problems are the same rows the web UI
# renders. What lives here is a git working copy and nothing else, which is
# why destroying one mid-run costs nothing that isn't already pushed.
#
# Generation is the same path, not a different one: a new project is a sprite
# whose repo happens to be empty. That is detectable — a clone with no commits —
# so there is one entrypoint rather than two scripts sharing most of a body.
set -euo pipefail

REPO_URL="${REPO_URL:?REPO_URL is required (https://github.com/owner/repo)}"
CMS_PROJECT_ID="${CMS_PROJECT_ID:?CMS_PROJECT_ID is required (CodeMySpec project UUID)}"

# The clone directory is chosen here, at runtime, and handed to the harness.
# It is deliberately not read back from the project row: that row is shared
# with every other checkout, so it cannot describe this container's disk.
#
# Named from the repo, NOT from APP_NAME: the image sets APP_NAME=my_app for
# the devbox generator path, and a `:-` default cannot tell an image-level ENV
# from one the operator passed. Reading it here silently cloned every repo into
# /workspace/my_app. APP_DIR is the override, and nothing else sets it.
APP_DIR="${APP_DIR:-/workspace/$(basename "${REPO_URL}" .git)}"

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
    clone_status=$?
    [ "${clone_status}" -eq 0 ] && git -C "${APP_DIR}" remote set-url origin "${REPO_URL}"
  else
    git clone "${REPO_URL}" "${APP_DIR}"
    clone_status=$?
  fi

  # `set -e` used to end the run here on git's bare exit 128, with the last line
  # of output being git's own — which says the host did not resolve and nothing
  # about what that meant for the sprite.
  #
  # Deliberately not falling through to "generate a new project". An
  # unreachable remote and an empty new remote look identical from here, and
  # guessing wrong means scaffolding a fresh tree over a repository that
  # already has history, then committing it. A sprite that stops is
  # recoverable; one that forks a project's history quietly is not.
  if [ "${clone_status}" -ne 0 ]; then
    log "FATAL: could not clone ${REPO_URL} (git exited ${clone_status})."
    log "       Not generating a new project instead: an unreachable repo and an"
    log "       empty new one are indistinguishable from here, and guessing wrong"
    log "       means scaffolding over history that already exists."
    log "       If this project has no repository yet, create it empty and point"
    log "       REPO_URL at it — an empty clone does reach the generate path."
    exit 1
  fi
fi

# --- generate, if the repo is empty ------------------------------------------
# The project row already exists in the central database, so there is nothing to
# fetch and no server API call to authenticate. That is what removed the blocker
# here: the previous version asked OAuthClient for a token, and a fresh container
# has no way to obtain one — the browser flow needs to reach a port that binds
# loopback *inside* the container by design.
if [ -z "$(git -C "${APP_DIR}" log --oneline -1 2>/dev/null)" ]; then
  log "Repo is empty — generating a new project"

  # module_name off the project row, not the repo name. It is what the harness
  # uses to map spec paths to modules, so a generated app that disagrees with it
  # produces components the requirement graph cannot link to files.
  #
  # `eval` loads the application without starting it, so the Repo has to be
  # started by hand. A raw table query rather than Repo.get/2 on the schema:
  # Project has encrypted columns, and loading the struct would need the Vault
  # up as well for a field we do not want.
  #
  # The value is fenced in a sentinel because release boot writes to stdout and
  # command substitution would swallow it into the app name.
  # On the light-harness path the project's identity comes from the server, on
  # the same exchange that gets the token. Reading it out of Postgres here is a
  # database dependency in the launcher of a harness whose whole premise is
  # holding no database — and there is no reason for that container to hold
  # credentials for one.
  if [ "${CMS_LIGHT_HARNESS:-}" = "1" ]; then
    : "${CMS_SERVER_URL:?CMS_LIGHT_HARNESS=1 needs CMS_SERVER_URL}"
    : "${CMS_DEPLOY_KEY:?CMS_LIGHT_HARNESS=1 needs CMS_DEPLOY_KEY}"

    APP_NAME="$(curl -sS --max-time 30 -X POST "${CMS_SERVER_URL}/api/sprite/token" \
      -H "Authorization: Bearer ${CMS_DEPLOY_KEY}" \
      -H "Content-Type: application/json" -d '{}' \
      | python3 -c 'import json, sys; print(json.load(sys.stdin).get("app_name") or "")')"
  else
  APP_NAME="$(CMS_PROJECT_ID="$CMS_PROJECT_ID" /opt/cms/bin/code_my_spec_cli eval '
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, _} = CodeMySpec.Repo.start_link(pool_size: 2, log: false)

    import Ecto.Query

    module_name =
      CodeMySpec.Repo.one(
        from(p in "projects",
          where: p.id == type(^System.fetch_env!("CMS_PROJECT_ID"), :binary_id),
          select: p.module_name
        )
      )

    IO.puts("__CMS_APP__" <> Macro.underscore(module_name))
  ' | sed -n 's/^__CMS_APP__//p' | tail -1)"
  fi

  [ -n "${APP_NAME}" ] || { echo "could not resolve module_name for ${CMS_PROJECT_ID}" >&2; exit 1; }
  log "Generating ${APP_NAME} with mix cms.new"

  # cms.new refuses to write into a non-empty directory and the clone already
  # made one (with .git in it), so generate beside it and move the tree in.
  tmp="$(mktemp -d)"
  mix cms.new "${tmp}/${APP_NAME}" --no-install
  # cms.new runs `git init`, and dotglob would move that .git over the clone's —
  # which fails, and would be wrong if it succeeded: the clone's .git is what
  # carries the remote we push back to.
  rm -rf "${tmp}/${APP_NAME}/.git"
  ( shopt -s dotglob; mv "${tmp}/${APP_NAME}"/* "${APP_DIR}/" )
  rm -rf "$tmp"

  cd "${APP_DIR}"

  log "Fetching dependencies"
  # Not optional: the analyzers gate on deps/<tool> existing, so without this
  # credo and sobelow report themselves unavailable and are silently skipped.
  mix deps.get

  log "Installing harness files"
  CMS_APP_DIR="${APP_DIR}" /opt/cms/bin/code_my_spec_cli eval '
    alias CodeMySpec.Environments.Environment
    alias CodeMySpec.McpServers.Bootstrap.Installers

    env = Environment.new(:local, System.fetch_env!("CMS_APP_DIR"))
    {installed, failures} = Installers.install_all(env)

    IO.puts("installed: " <> Enum.join(installed, ", "))
    for {label, reason} <- failures, do: IO.puts("FAILED #{label}: #{inspect(reason)}")
  '

  log "Committing and pushing"
  git -C "${APP_DIR}" config user.name "CodeMySpec"
  git -C "${APP_DIR}" config user.email "noreply@codemyspec.com"
  git -C "${APP_DIR}" add -A
  git -C "${APP_DIR}" commit -q -m "Generate ${APP_NAME} with mix cms.new

Harness-native Phoenix project: satisfies every CodeMySpec ProjectSetup check
on first sync, with no agent-driven setup pass."

  if [ -n "${GITHUB_TOKEN:-}" ]; then
    git -C "${APP_DIR}" push -q \
      "https://x-access-token:${GITHUB_TOKEN}@${REPO_URL#https://}" HEAD:main 2>&1 \
      | sed 's/x-access-token:[^@]*@/x-access-token:***@/g'
  else
    log "No GITHUB_TOKEN — generated and committed locally, not pushed"
  fi
fi

# --- agent home ---------------------------------------------------------------
# The agent runs as a non-root user (see the Dockerfile) but its credentials
# arrive on a volume written by whoever logged in, which is root. Files land
# 0600 root, so the agent cannot read its own login and Claude Code reports
# "Not logged in" — a confusing way to say "wrong uid".
#
# The entrypoint is still root at this point, so this is the one place it can be
# fixed without granting the agent anything.
if [ -d /home/agent/.claude ]; then
  chown -R agent:agent /home/agent
fi

# The working copy belongs to the agent, but this script — and anything else in
# the entrypoint — runs as root. Git refuses to operate on a repository owned by
# somebody else ("detected dubious ownership") and that refusal is fatal, so a
# root-side clone or push dies after the chown rather than before it.
#
# Both users are declared safe rather than picking one owner, because the split
# is deliberate: root sets the container up, the agent does the work in it.
git config --global --add safe.directory "${APP_DIR}" 2>/dev/null || true
su agent -c "git config --global --add safe.directory '${APP_DIR}'" 2>/dev/null || true
chown -R agent:agent "${APP_DIR}" 2>/dev/null || true

# --- talking to the server -----------------------------------------------------
# Defined here because the plugin install below needs them: the manifest has to
# carry the token before Claude Code snapshots it.

exchange_token() {
  : "${CMS_SERVER_URL:?CMS_LIGHT_HARNESS=1 needs CMS_SERVER_URL}"
  : "${CMS_DEPLOY_KEY:?CMS_LIGHT_HARNESS=1 needs CMS_DEPLOY_KEY}"

  log "Trading the deploy key for an access token"

  CMS_ACCESS_TOKEN="$(curl -sS -X POST "${CMS_SERVER_URL}/api/sprite/token" \
    -H "Authorization: Bearer ${CMS_DEPLOY_KEY}" \
    -H "Content-Type: application/json" -d '{}' \
    | python3 -c 'import sys, json; print(json.load(sys.stdin).get("access_token", ""))')"

  # Refuse rather than start half-configured. A harness that comes up with no
  # token serves hooks perfectly well and gives the agent no tools at all, and
  # "no tools" reads as a broken plugin rather than as a failed exchange.
  [ -n "${CMS_ACCESS_TOKEN}" ] || {
    log "FATAL: could not trade the deploy key for an access token at ${CMS_SERVER_URL}."
    log "       The agent would come up with no harness tools. Refusing to start."
    exit 1
  }

  export CMS_ACCESS_TOKEN
}

patch_marketplace_manifest() {
  python3 - "${CMS_SERVER_URL}/mcp/harness" "${CMS_ACCESS_TOKEN}" "${CMS_PROJECT_ID}" <<'PATCH'
import json, pathlib, sys

url, token, project_id = sys.argv[1:4]
manifest = pathlib.Path(
    "/home/agent/.claude/plugins/marketplaces/codemyspec"
    "/plugins/codemyspec/.claude-plugin/plugin.json"
)

if not manifest.exists():
    print(f"WARNING: no marketplace manifest at {manifest} — the agent will have no "
          "harness tools.")
    raise SystemExit(0)

m = json.loads(manifest.read_text())
env = m.setdefault("mcpServers", {}).setdefault("local", {}).setdefault("env", {})
env["CMS_MCP_BASE_URL"] = url
env["CMS_MCP_TOKEN"] = token
env["CMS_PROJECT_ID"] = project_id
manifest.write_text(json.dumps(m, indent=2))
print(f"pointed the plugin's MCP at {url}")
PATCH

  chown -R agent:agent /home/agent/.claude 2>/dev/null || true
}

# --- the agent's credentials ---------------------------------------------------
# Claude Code needs to be logged in, and nothing here logs it in. Two ways to
# supply that, both from outside:
#
#   1. A volume holding an already-authenticated home (how this has been done
#      so far — `cms-agent-home-v2` on the dev machine):
#
#        docker run -v cms-agent-home-v2:/home/agent/.claude ...
#
#   2. A long-lived token, which is what an unattended sprite on a fresh host
#      wants:
#
#        claude setup-token                    # on a machine with a browser
#        docker run -e CLAUDE_CODE_OAUTH_TOKEN=... ...
#
# Checked here rather than discovered at the first agent turn, because
# "Not logged in" arrives as a turn that does nothing and looks like a hung
# sprite. On macOS the credential lives in the Keychain, not in ~/.claude, so
# bind-mounting the host's directory carries config and no auth — that looks
# like it should work and does not.
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ ! -f /home/agent/.claude/.credentials.json ]; then
  log "WARNING: no Claude credential. Mount an authenticated home at"
  log "         /home/agent/.claude, or pass CLAUDE_CODE_OAUTH_TOKEN."
  log "         The agent will start and every turn will report 'Not logged in'."
fi

# The image symlinks ~/.claude.json into ~/.claude so both survive one volume.
# A mounted volume replaces the directory the symlink pointed into, so it is
# re-made here rather than baked.
if [ -f /home/agent/.claude/claude.json ]; then
  ln -sfn /home/agent/.claude/claude.json /home/agent/.claude.json
  chown -h agent:agent /home/agent/.claude.json 2>/dev/null || true
fi

# --- the agent's harness tools -------------------------------------------------
# Without the plugin the agent has no `get_next_requirement`, no `start_task`,
# and — the part that actually ends the run — no stop hook, so nothing forces it
# back into the loop when it decides it is finished. `claude mcp list` shows only
# the user's own remote servers, which reads as "the harness is down" rather than
# "the harness was never wired up".
#
# This has to happen before the agent is launched, not from inside it: hooks and
# plugin agents are read once at session start, so a plugin installed by a
# running session takes effect no earlier than the next one.
#
# Both commands are idempotent, so a restarted container re-runs them for free.
# Failure is not fatal — a sprite with a working copy and no plugin is still
# worth handing to a human — but it is loud, because every downstream symptom
# looks like something else.
if [ -d /home/agent/.claude ]; then
  log "Installing the CodeMySpec plugin"
  su agent -c "claude plugin marketplace add Code-My-Spec/plugins" >/dev/null 2>&1 \
    || log "WARNING: could not add the codemyspec marketplace — the agent will have no harness tools"

  # Patch the marketplace copy *before* installing, and reinstall if something
  # is already there.
  #
  # Claude Code snapshots a plugin's MCP config when it installs, into
  # plugins/cache/<marketplace>/<plugin>/<version>/. Editing that snapshot
  # afterwards does nothing — not even adding a whole new server, which is how
  # this was finally pinned down. Install-then-patch leaves the agent with no
  # harness tools and a log that says only that the server "never finished
  # connecting".
  if [ "${CMS_LIGHT_HARNESS:-}" = "1" ]; then
    exchange_token
    patch_marketplace_manifest
    su agent -c "claude plugin uninstall codemyspec@codemyspec" >/dev/null 2>&1 || true
  fi

  su agent -c "claude plugin install codemyspec@codemyspec" >/dev/null 2>&1 \
    || log "WARNING: could not install the codemyspec plugin — the agent will have no harness tools"
  su agent -c "claude plugin list" 2>/dev/null | grep -q codemyspec \
    && log "Plugin installed" \
    || log "WARNING: codemyspec plugin is NOT installed; expect 'no MCP tools' and a run that stops at the first stop hook"
fi

# --- which port the hooks actually post to -------------------------------------
# Read from the installed plugin rather than assumed, because guessing it wrong
# does not fail: the hooks POST into a closed port, curl exits non-zero, and
# Claude Code treats a hook that could not be reached as a hook with nothing to
# say. Session ids are never injected and the stop hook never gates, so the run
# looks like a harness that approves of everything.
#
# A whole drill was lost to this. The published plugin posts to 4003; this script
# had 4004 (taken from the newer copy in the repo) and a comment claiming 4005.
# All three disagreed, and the run still reported success — the agent noticed the
# silence and drove the hooks by hand with curl.
#
# The installed manifest is the only authority: it is the file the running hooks
# were read from.
detect_harness_port() {
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

# Fallback for a layout change in installed_plugins.json: any hooks.json under
# the plugin cache is still closer to the truth than a hardcoded number.
if not roots:
    roots = list(pathlib.Path("/home/agent/.claude/plugins").glob("*/*/*/*"))

ports = collections.Counter()
for root in roots:
    hooks = root / "hooks" / "hooks.json"
    if hooks.exists():
        ports.update(re.findall(r"localhost:(\d+)", hooks.read_text()))

if ports:
    print(ports.most_common(1)[0][0])
PY
}

DETECTED_HARNESS_PORT="$(detect_harness_port)"

# --- dependencies -------------------------------------------------------------
# Also on the clone path, not just after generating. A sprite that attaches to
# an existing repo starts with no deps/ at all, and the analyzers gate on
# deps/<tool> existing — so credo and sobelow report themselves unavailable and
# are skipped, and nothing compiles. Cheap when they are already fetched.
if [ -f "${APP_DIR}/mix.exs" ]; then
  log "Fetching dependencies"
  (cd "${APP_DIR}" && mix deps.get) || log "deps.get failed — the agent will need to sort this out"

  # Hand the toolchain to the agent.
  #
  # This runs as root, so deps/, _build/ and the Mix home it populates all come
  # out root-owned — and the agent is not root. Every compile then fails on
  # permissions, and the failure is recoverable enough that an agent will just
  # work around it with redirected paths for the rest of the run rather than
  # report it. One did, for eighteen requirements, and only mentioned it in
  # passing at the end.
  #
  # MIX_HOME moves rather than being chowned: it holds hex and rebar for
  # whoever runs mix, and root still needs its own copy for the entrypoint.
  install -d -o agent -g agent /home/agent/.mix
  cp -a "${MIX_HOME:-/root/.mix}/." /home/agent/.mix/ 2>/dev/null || true
  chown -R agent:agent /home/agent/.mix

  # Hex too, not just Mix. The harness now runs as `agent` (see the exec at the
  # bottom), so every `mix` it spawns needs a hex cache it can read and write —
  # root's is neither.
  install -d -o agent -g agent /home/agent/.hex
  cp -a "${HEX_HOME:-/root/.hex}/." /home/agent/.hex/ 2>/dev/null || true
  chown -R agent:agent /home/agent/.hex

  chown -R agent:agent "${APP_DIR}"
fi

# The harness writes its own state and logs under $HOME; as `agent` that is
# /home/agent/.codemyspec, which root has to create before dropping privileges.
install -d -o agent -g agent /home/agent/.codemyspec

# --- harness -----------------------------------------------------------------
# No migrations: the schema belongs to the server, which owns those rows. The
# sprite role has DML only, so an accidental migration fails loudly rather than
# altering a table the web app is serving from. (Migrator.run/0 no-ops on
# :dev_sprite for the same reason.)
log "Starting the harness for project ${CMS_PROJECT_ID}"
cd "${APP_DIR}"

export CMS_PROJECT_ID
export CMS_MCP_WORKING_DIR="${APP_DIR}"

# Documented for whoever launches the agent: run it as `agent` with this
# MIX_HOME, or it falls back to root's and cannot write there. Prefer
# `devbox-agent` over bare `claude` — it restarts the agent when a transient
# upstream error cuts a turn short, which unattended is the difference between
# a run that finishes and one that stops at the first 529.
#   docker exec -d -u agent -e MIX_HOME=/home/agent/.mix <container> devbox-agent
# Optional. Without it `ask_user` cannot reach anybody, which only matters when
# the agent hits a manual requirement — and an unattended sprite has no
# terminal to fall back to.
export CMS_DEPLOY_KEY="${CMS_DEPLOY_KEY:-}"

# Run the harness as `agent`, the same uid as the agent it serves.
#
# It used to run as root, and root and the agent share the project's `_build`.
# Every analyzer the harness spawned left root-owned artifacts there —
# `_build/test/lib/<app>/.mix/.mix_test_failures` and `compile.elixir` were both
# root-owned after the last run — and the agent's next `mix test` died on
# EACCES trying to rewrite them. The chowns above only fix the state at
# startup; the harness goes on re-creating root-owned files for the rest of the
# run.
#
# The failure mode is worse than a crash, because it is recoverable: an agent
# that cannot write `_build` will quietly redirect to another build path and
# carry on rather than report it. There is a `_build/test_root_owned` directory
# in the last run's working copy that is exactly that — a workaround nobody
# asked for and nobody saw. This script already warns about the same trap for
# MIX_HOME a few lines up; `_build` had the identical problem and no fix.
#
# setpriv rather than su: it preserves the environment exactly, and everything
# below CMS_* has already been exported into it. HOME and MIX_HOME are set
# explicitly because those are the two su would have changed for us.
export HOME=/home/agent
export MIX_HOME=/home/agent/.mix
export HEX_HOME=/home/agent/.hex

# CMS_LIGHT_HARNESS=1 serves this project with the light harness instead of the
# full local application.
#
# Opt-in, and deliberately not the default yet: the CLI path below is what every
# drill so far has run on, and switching the thing under test at the same time as
# the thing being tested makes a failed drill say nothing about either.
#
# Two differences, and only two:
#
#   * It serves the hooks on whatever port the installed plugin posts to, found
#     by reading that plugin's hooks.json above. The harness serves those paths
#     already, so nothing about the plugin changes — see
#     cms_harness/config/runtime.exs.
#   * The MCP tools come from the server rather than from a process here. A
#     deploy key cannot reach them (the mount takes an OAuth token), so the key
#     is traded for one first. That token is what the agent's MCP client holds.
if [ "${CMS_LIGHT_HARNESS:-}" = "1" ]; then
  # The token was exchanged and written into the plugin manifest before the
  # install above, because that is the only moment Claude Code reads it.
  [ -n "${CMS_ACCESS_TOKEN:-}" ] || exchange_token

  # The relay reads these and sends them as Authorization / X-Project-ID. The
  # server has no disk to resolve a working directory into a project, so it is
  # told the id outright.
  export CMS_MCP_TOKEN="${CMS_ACCESS_TOKEN}"

  if [ -n "${CMS_HARNESS_PORT:-}" ]; then
    :
  elif [ -n "${DETECTED_HARNESS_PORT:-}" ]; then
    export CMS_HARNESS_PORT="${DETECTED_HARNESS_PORT}"
    log "Hooks post to ${CMS_HARNESS_PORT} (read from the installed plugin)"
  else
    export CMS_HARNESS_PORT=4003
    log "WARNING: could not read a hook port from the installed plugin; guessing ${CMS_HARNESS_PORT}. If hooks do not fire, this is why."
  fi
  export CMS_PROJECT_DIR="${APP_DIR}"

  # Where the embedding model is. `mix release` copies priv/ in, so the CLI
  # release already carries one — found rather than shipped a second time.
  # Resolved by glob because the path contains the release's version, and
  # hardcoding that means it works until the next version bump and then does
  # not, in a way that looks like the model is missing.
  if [ -z "${CMS_MODEL_PATH:-}" ]; then
    for candidate in /opt/cms/lib/code_my_spec-*/priv/models; do
      if [ -f "${candidate}/all-MiniLM-L6-v2.onnx" ]; then
        export CMS_MODEL_PATH="${candidate}"
        break
      fi
    done
  fi

  if [ -n "${CMS_MODEL_PATH:-}" ]; then
    log "Embedding model: ${CMS_MODEL_PATH}"
  else
    log "WARNING: no embedding model found under /opt/cms. Search will be"
    log "         degraded; set CMS_MODEL_PATH if one lives elsewhere."
  fi

  # A failed auth is cached, and the cache outlives the run. This home is a
  # volume reused across drills, so a single 401 disables the MCP server for
  # every later run, presenting as "the server never finished connecting".
  python3 - <<'RESET'
import json, pathlib

p = pathlib.Path("/home/agent/.claude/mcp-needs-auth-cache.json")
if p.exists():
    cache = json.loads(p.read_text())
    stale = [k for k in cache if "codemyspec" in k]
    for k in stale:
        cache.pop(k)
    if stale:
        p.write_text(json.dumps(cache))
        print(f"cleared a cached auth failure for {', '.join(stale)}")
RESET

  chown -R agent:agent /home/agent/.claude 2>/dev/null || true

  log "Starting the light harness on ${CMS_HARNESS_PORT} against ${CMS_SERVER_URL}"

  exec setpriv --reuid=agent --regid=agent --init-groups \
    /opt/cms_harness/bin/cms_harness start
fi

exec setpriv --reuid=agent --regid=agent --init-groups \
  /opt/cms/bin/code_my_spec_cli start
