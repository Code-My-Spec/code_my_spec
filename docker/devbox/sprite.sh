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
    git -C "${APP_DIR}" remote set-url origin "${REPO_URL}"
  else
    git clone "${REPO_URL}" "${APP_DIR}"
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
  chown -R agent:agent "${APP_DIR}"
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

# Documented for whoever launches the agent: run it as `agent` with this
# MIX_HOME, or it falls back to root's and cannot write there.
#   docker exec -u agent -e MIX_HOME=/home/agent/.mix ... claude ...
# Optional. Without it `ask_user` cannot reach anybody, which only matters when
# the agent hits a manual requirement — and an unattended sprite has no
# terminal to fall back to.
export CMS_DEPLOY_KEY="${CMS_DEPLOY_KEY:-}"

exec /opt/cms/bin/code_my_spec_cli start
