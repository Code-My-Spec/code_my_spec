#!/bin/bash
set -euo pipefail

# Sync a single project's data between environments — the project row, its
# components, and its stories/versions. Never the account, its members, its
# users, or any other project the account owns: see
# CodeMySpec.Utils.Data's moduledoc for why this used to sync whole accounts
# and why that broke.
# Usage: ./scripts/sync-project.sh <project-id> <source-env> <dest-env> [--dry-run]
# Example: ./scripts/sync-project.sh 49d80233-5e7f-4590-8fff-e6af922ce70d dev prod
# Example: ./scripts/sync-project.sh 49d80233-5e7f-4590-8fff-e6af922ce70d prod uat --dry-run

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

error() {
    echo -e "${RED}Error: $1${NC}" >&2
    exit 1
}

info() {
    echo -e "${GREEN}$1${NC}"
}

warn() {
    echo -e "${YELLOW}$1${NC}"
}

# Validate arguments
if [ $# -lt 3 ]; then
    error "Usage: ./scripts/sync-project.sh <project-id> <source-env> <dest-env> [--dry-run]"
fi

PROJECT_ID=$1
SOURCE_ENV=$2
DEST_ENV=$3
DRY_RUN=""

if [ "${4:-}" = "--dry-run" ]; then
    DRY_RUN="--dry-run"
    warn "Running in DRY RUN mode - no changes will be made"
fi

# Validate environments
if [[ ! "$SOURCE_ENV" =~ ^(dev|uat|prod)$ ]]; then
    error "Invalid source environment: $SOURCE_ENV. Must be 'dev', 'uat', or 'prod'"
fi

if [[ ! "$DEST_ENV" =~ ^(dev|uat|prod)$ ]]; then
    error "Invalid destination environment: $DEST_ENV. Must be 'dev', 'uat', or 'prod'"
fi

if [ "$SOURCE_ENV" = "$DEST_ENV" ]; then
    error "Source and destination environments cannot be the same"
fi

EXPORT_FILE="/tmp/project_${PROJECT_ID}_${SOURCE_ENV}_to_${DEST_ENV}.json"

# Get app name for Fly environments
get_app_name() {
    local env=$1
    if [ "$env" = "dev" ]; then
        echo ""
    else
        echo "code-my-spec-${env}"
    fi
}

SOURCE_APP=$(get_app_name "$SOURCE_ENV")
DEST_APP=$(get_app_name "$DEST_ENV")

# Step 1: Export from source
info "Step 1: Exporting project ${PROJECT_ID} from ${SOURCE_ENV}..."

if [ "$SOURCE_ENV" = "dev" ]; then
    # Export from local dev
    mix sync.data export --project-id "${PROJECT_ID}" --output "${EXPORT_FILE}"
else
    # Export from remote environment
    fly ssh console -a "${SOURCE_APP}" -C "/app/bin/code_my_spec rpc 'CodeMySpec.Release.export_project(\"${PROJECT_ID}\", \"/tmp/project_${PROJECT_ID}.json\")'"
    fly ssh sftp get "/tmp/project_${PROJECT_ID}.json" "${EXPORT_FILE}" -a "${SOURCE_APP}"
fi

if [ ! -f "${EXPORT_FILE}" ]; then
    error "Export failed - ${EXPORT_FILE} not found"
fi

info " Export complete: ${EXPORT_FILE}"

# Step 2: Upload to destination (if not dev)
if [ "$DEST_ENV" != "dev" ]; then
    if [ -z "${DRY_RUN}" ]; then
        info "Step 2: Uploading to ${DEST_ENV}..."
        fly ssh console -a "${DEST_APP}" -C "sh -c 'cat > /tmp/project_${PROJECT_ID}.json'" < "${EXPORT_FILE}"
        info " Upload complete"
    else
        info "Step 2: [DRY RUN] Skipping upload to ${DEST_ENV}"
    fi
fi

# Step 3: Import to destination
if [ -z "${DRY_RUN}" ]; then
    info "Step 3: Importing to ${DEST_ENV}..."
    if [ "$DEST_ENV" = "dev" ]; then
        mix sync.data import --file "${EXPORT_FILE}"
    else
        fly ssh console -a "${DEST_APP}" -C "/app/bin/code_my_spec rpc 'CodeMySpec.Release.import_project(\"/tmp/project_${PROJECT_ID}.json\")'"
    fi
    info " Import complete"
else
    info "Step 3: Running dry-run import on ${DEST_ENV}..."
    if [ "$DEST_ENV" = "dev" ]; then
        mix sync.data import --file "${EXPORT_FILE}" --dry-run
    else
        fly ssh console -a "${DEST_APP}" -C "/app/bin/code_my_spec rpc 'CodeMySpec.Release.import_project(\"/tmp/project_${PROJECT_ID}.json\", dry_run: true)'"
    fi
    info " Dry-run complete"
fi

info "Done! Project ${PROJECT_ID} synced from ${SOURCE_ENV} to ${DEST_ENV}."
