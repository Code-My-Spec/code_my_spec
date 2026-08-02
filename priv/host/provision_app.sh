#!/usr/bin/env bash
#
# Provision one Phoenix release app on a shared host.
#
#   provision_app.sh <app> <port> [domain]
#
# Idempotent: every step checks before it acts, so re-running after a partial
# failure completes the job rather than erroring on what already exists. That
# matters more than it sounds — the first run is the one most likely to fail
# partway, and a script you cannot safely re-run turns that into a manual
# cleanup.
#
# What it does NOT do: install packages, tune Postgres, or configure backups.
# Those are host-level and belong in the host runbook, not in a per-app script
# that runs twenty times.

set -euo pipefail

APP="${1:?usage: provision_app.sh <app> <port> [domain]}"
PORT="${2:?usage: provision_app.sh <app> <port> [domain]}"
DOMAIN="${3:-}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES="$HERE/templates"

ADMIN_AGE_PUBKEY="${ADMIN_AGE_PUBKEY:?ADMIN_AGE_PUBKEY must be set — secrets are encrypted to the app key AND the admin key, so that losing a box does not lose the ability to read or rotate its secrets}"

# Names become Unix users, Postgres roles and systemd unit names. Anything
# outside this set has to be quoted differently in each of those places, and
# the quoting is where injection lives.
if ! [[ "$APP" =~ ^[a-z][a-z0-9_]{1,30}$ ]]; then
  echo "app name must be lowercase alphanumeric/underscore, starting with a letter: $APP" >&2
  exit 2
fi

if ! [[ "$PORT" =~ ^[0-9]{4,5}$ ]]; then
  echo "port must be numeric: $PORT" >&2
  exit 2
fi

log() { printf '  %s\n' "$*"; }

echo "provisioning $APP on port $PORT"

# ---------------------------------------------------------------- 1. user
if id -u "$APP" >/dev/null 2>&1; then
  log "user $APP exists"
else
  # No login shell and no password: this account exists to own files and run a
  # service, and a service account you can log into is a service account
  # somebody eventually logs into.
  adduser --system --group --home "/opt/$APP" --shell /usr/sbin/nologin "$APP"
  log "created user $APP"
fi

install -d -o "$APP" -g "$APP" -m 750 "/opt/$APP"
install -d -o "$APP" -g "$APP" -m 750 "/opt/$APP/tmp"
# Re-assert, not just create: a release copy (`cp -a src/. dst/`, or a tarball
# carrying a 755 top dir) silently widens this back to 755, and a re-run of
# provision is where that gets corrected.
chmod 750 "/opt/$APP"
log "/opt/$APP is 750 $APP:$APP"

# ------------------------------------------------------------- 2. age key
install -d -o root -g root -m 755 "/etc/$APP"
KEYFILE="/etc/$APP/age.key"

if [[ -f "$KEYFILE" ]]; then
  log "age key exists"
else
  # Subshell so the umask does not outlive the key. Set at script scope it
  # leaks into every later file — which made Caddy's own config 600 root:root
  # and Caddy, running as its own user, could not read the site it was being
  # asked to serve.
  ( umask 077 && age-keygen -o "$KEYFILE" 2>/dev/null )
  chown "$APP:$APP" "$KEYFILE"
  chmod 400 "$KEYFILE"
  log "generated age key"
fi

APP_AGE_PUBKEY="$(age-keygen -y "$KEYFILE")"
log "app recipient $APP_AGE_PUBKEY"

# --------------------------------------------------------- 2 & 3. postgres
psql_super() { su - postgres -c "psql -tAc \"$1\""; }

# A password per role, generated here and carried only in the encrypted
# secrets file. Peer authentication would be simpler, but the app connects
# over TCP to localhost and peer does not apply there — and a role with no
# password behind `trust` is a role every process on the box can assume.
DB_PASSWORD=""

if [[ "$(psql_super "SELECT 1 FROM pg_roles WHERE rolname='$APP'")" == "1" ]]; then
  log "postgres role $APP exists"
else
  DB_PASSWORD="$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 32)"
  su - postgres -c "psql -q -c \"CREATE ROLE \\\"$APP\\\" LOGIN PASSWORD '$DB_PASSWORD';\""
  log "created postgres role $APP with a generated password"
fi

if [[ "$(psql_super "SELECT 1 FROM pg_database WHERE datname='$APP'")" == "1" ]]; then
  log "database $APP exists"
else
  su - postgres -c "createdb -O '$APP' '$APP'"
  log "created database $APP owned by $APP"
fi

# Not optional, and the reason it is called out: Postgres grants CONNECT to
# PUBLIC on every new database. Without this revoke, every app role on the box
# can connect to every other app's database — the isolation is off by default
# and nothing warns you.
su - postgres -c "psql -q -d '$APP' -c \"REVOKE CONNECT ON DATABASE \\\"$APP\\\" FROM PUBLIC;\""
su - postgres -c "psql -q -d '$APP' -c \"GRANT CONNECT ON DATABASE \\\"$APP\\\" TO \\\"$APP\\\";\""
log "CONNECT on $APP revoked from PUBLIC, granted to $APP only"

# --------------------------------------------------------------- 4. sops
#
# After Postgres, because the secrets file carries DATABASE_URL — and that
# needs the role's generated password to exist first.
SOPS_CONFIG="/opt/$APP/.sops.yaml"
SECRETS="/opt/$APP/secrets.enc.yaml"

# Two recipients, always. The app key alone means a lost box is lost secrets;
# the admin key is what makes them readable and rotatable from anywhere else.
cat > "$SOPS_CONFIG" <<YAML
creation_rules:
  - path_regex: secrets\.enc\.yaml\$
    age: "$APP_AGE_PUBKEY,$ADMIN_AGE_PUBKEY"
YAML
chown "$APP:$APP" "$SOPS_CONFIG"

if [[ -f "$SECRETS" ]]; then
  # Re-encrypt rather than rewrite: the file may already hold real secrets,
  # and this is also how a rotated key gets picked up.
  ( cd "/opt/$APP" && sops updatekeys --yes "$SECRETS" >/dev/null 2>&1 ) || true
  log "secrets file exists (recipients refreshed)"
else
  TMP="$(mktemp)"
  # A placeholder rather than an empty file: sops needs something to encrypt,
  # and DATABASE_URL is the one every app needs anyway.
  cat > "$TMP" <<YAML
DATABASE_URL: postgres://$APP:$DB_PASSWORD@localhost/$APP
SECRET_KEY_BASE: $(head -c 48 /dev/urandom | base64 | tr -d '\n')
YAML
  # `--config /dev/null` because sops prefers .sops.yaml over an explicit
  # --age, and the temp file's path does not match the creation rule — which
  # surfaces as "no matching creation rules found" while pointing at a config
  # that is perfectly correct for the real file.
  ( cd "/opt/$APP" && sops --config /dev/null --encrypt \
      --age "$APP_AGE_PUBKEY,$ADMIN_AGE_PUBKEY" \
      --input-type yaml --output-type yaml "$TMP" > "$SECRETS" )
  rm -f "$TMP"
  chown "$APP:$APP" "$SECRETS"
  chmod 640 "$SECRETS"
  log "created encrypted secrets file"
fi

# ------------------------------------------------------------ 6. systemd
UNIT="/etc/systemd/system/$APP.service"
sed -e "s/{{APP}}/$APP/g" -e "s/{{PORT}}/$PORT/g" "$TEMPLATES/app.service" > "$UNIT"
systemctl daemon-reload
systemctl enable "$APP" >/dev/null 2>&1 || true
log "wrote $UNIT"

# -------------------------------------------------------------- 7. caddy
if [[ -n "$DOMAIN" ]]; then
  SITE="/etc/caddy/sites/$APP.caddy"
  install -d -o root -g root -m 755 /etc/caddy/sites
  sed -e "s/{{DOMAIN}}/$DOMAIN/g" -e "s/{{PORT}}/$PORT/g" "$TEMPLATES/caddy-site" > "$SITE"
  # Caddy runs as its own user and has to read this.
  chmod 644 "$SITE"

  # Validate before reloading. A bad block takes down every site on the box,
  # not just this one, and `caddy reload` on an invalid config leaves the old
  # one running — which looks like the change silently not applying.
  if caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
    systemctl reload caddy
    log "wrote $SITE and reloaded caddy"
  else
    rm -f "$SITE"
    echo "caddy config invalid after adding $APP — block removed, caddy untouched" >&2
    exit 1
  fi
else
  log "no domain given — skipping caddy block"
fi

echo "done: $APP on :$PORT${DOMAIN:+ at $DOMAIN}"
echo
echo "next:  put the release in /opt/$APP, then: systemctl start $APP"
echo "check: $HERE/verify_isolation.sh $APP <other-app>"
