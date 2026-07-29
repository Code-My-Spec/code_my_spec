#!/bin/bash
# devbox new-project — the "I want a new project" path, end to end.
#
# Takes an empty GitHub repo and a CodeMySpec project, and leaves behind a
# generated, harness-native Phoenix app that is committed, pushed, linked to
# the project, and running — with an agent attached.
#
# Idempotent: /workspace is a mounted volume, so a restart reuses whatever the
# first run produced rather than regenerating over it.
set -euo pipefail

APP_NAME="${APP_NAME:?APP_NAME is required}"
REPO_URL="${REPO_URL:?REPO_URL is required (https://github.com/owner/repo)}"
PROJECT_ID="${PROJECT_ID:?PROJECT_ID is required (CodeMySpec project UUID)}"
GITHUB_TOKEN="${GITHUB_TOKEN:?GITHUB_TOKEN is required (repo scope)}"

APP_DIR="/workspace/${APP_NAME}"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# --- postgres ---------------------------------------------------------------
log "Starting Postgres"
su postgres -c "pg_ctl -D ${PGDATA} -l /tmp/postgres.log -w start"
su postgres -c "psql -tAc \"ALTER USER postgres WITH PASSWORD 'postgres'\"" >/dev/null

# --- clone + generate -------------------------------------------------------
if [ ! -f "${APP_DIR}/mix.exs" ]; then
  log "Cloning ${REPO_URL}"
  # Token goes in the remote URL only for the initial clone; it is rewritten to
  # a clean URL below so it never lands in .git/config on the mounted volume.
  authed_url="https://x-access-token:${GITHUB_TOKEN}@${REPO_URL#https://}"
  rm -rf "${APP_DIR}"
  git clone "$authed_url" "${APP_DIR}" 2>&1 | sed 's/x-access-token:[^@]*@/x-access-token:***@/g'

  log "Generating ${APP_NAME} with mix cms.new"
  # cms.new refuses to generate over a non-empty directory, and the clone
  # already created one (with .git in it). Generate beside it, then move the
  # tree in, preserving the clone's .git.
  tmp="$(mktemp -d)"
  mix cms.new "${tmp}/${APP_NAME}" --no-install
  ( shopt -s dotglob; mv "${tmp}/${APP_NAME}"/* "${APP_DIR}/" )
  rm -rf "$tmp"
else
  log "Reusing existing project at ${APP_DIR}"
fi

cd "${APP_DIR}"

log "Fetching dependencies"
mix deps.get

log "Setting up the database"
mix ecto.create
mix ecto.migrate

# --- link to the CodeMySpec project -----------------------------------------
# This is what the init_project MCP tool does, minus the MCP frame: resolve the
# project from the server with the mounted OAuth session, write the local
# record with local_path, and install the harness files. Doing it here means
# the agent starts against an already-linked project instead of spending its
# first turns on setup.
log "Linking to CodeMySpec project ${PROJECT_ID}"
PROJECT_ID="$PROJECT_ID" APP_DIR="$APP_DIR" /opt/cms/bin/code_my_spec_cli eval '
  alias CodeMySpec.{Repo, Projects.Project}
  alias CodeMySpec.Auth.OAuthClient
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.McpServers.Bootstrap.Installers

  project_id = System.fetch_env!("PROJECT_ID")
  app_dir = System.fetch_env!("APP_DIR")

  {:ok, token} = OAuthClient.get_token()
  url = OAuthClient.get_server_url() <> "/api/projects"

  {:ok, %{status: 200, body: %{"projects" => projects}}} =
    Req.get(url, headers: [{"authorization", "Bearer " <> token}])

  data = Enum.find(projects, &(&1["id"] == project_id)) || raise "project not found: #{project_id}"

  client_user_id =
    case OAuthClient.get_active_client_user() do
      {:ok, %{id: id}} -> id
      _ -> nil
    end

  attrs = %{
    id: data["id"], name: data["name"], description: data["description"],
    module_name: data["module_name"], code_repo: data["code_repo"],
    docs_repo: data["docs_repo"], client_api_url: data["client_api_url"],
    account_id: data["account_id"], local_path: app_dir,
    client_user_id: client_user_id, status: :created
  }

  {:ok, project} =
    %Project{}
    |> Project.bootstrap_changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:name, :description, :module_name, :code_repo,
                               :docs_repo, :client_api_url, :local_path, :client_user_id]},
      conflict_target: :id, returning: true
    )

  {installed, failures} = Installers.install_all(Environment.new(:local, app_dir))
  IO.puts("linked: #{project.name}")
  IO.puts("installed: #{Enum.join(installed, ", ")}")
  for {label, reason} <- failures, do: IO.puts("FAILED #{label}: #{inspect(reason)}")
'

# --- commit + push ----------------------------------------------------------
if [ -z "$(git -C "${APP_DIR}" log --oneline -1 2>/dev/null)" ]; then
  log "Pushing the generated project"
  git -C "${APP_DIR}" config user.name "CodeMySpec"
  git -C "${APP_DIR}" config user.email "noreply@codemyspec.com"
  git -C "${APP_DIR}" add -A
  git -C "${APP_DIR}" commit -q -m "Generate ${APP_NAME} with mix cms.new

Harness-native Phoenix project: satisfies every CodeMySpec ProjectSetup
check on first sync, with no agent-driven setup pass."
  git -C "${APP_DIR}" push -q \
    "https://x-access-token:${GITHUB_TOKEN}@${REPO_URL#https://}" HEAD:main 2>&1 \
    | sed 's/x-access-token:[^@]*@/x-access-token:***@/g'
  # Leave a clean remote behind so the token isn't persisted on the volume.
  git -C "${APP_DIR}" remote set-url origin "${REPO_URL}"
else
  log "Repo already has commits — skipping push"
fi

# --- harness + app ----------------------------------------------------------
log "Starting the cms harness on :4003"
cms start &

log "Starting ${APP_NAME} on :4000"
exec mix phx.server
