#!/usr/bin/env bash
# Setup script for a Claude Code cloud environment (claude.ai/code) that runs
# the CodeMySpec harness for this repo. Paste the whole file into the
# environment's setup-script box. It runs as root, before Claude starts, and its
# filesystem result is cached between sessions.
#
# It installs the toolchain (OTP, Elixir, sops), installs the published
# codemyspec plugin, and drops /usr/local/bin/cms-cloud-session, a SessionStart
# hook that onboards this checkout and starts the harness on every session.
# Nothing in the repo has to change.
#
# Environment variables (set them in the environment, not here):
#   CMS_SERVER_URL   e.g. https://dev.codemyspec.com (device approval is prompted)
set -euo pipefail

OTP_VERSION=28.1
ELIXIR_VERSION=1.19.4
SOPS_VERSION=3.10.2

# Downloads to a file and, when the network allowlist blocks it, says which URL
# and which host (after redirects) to allow, instead of curl's bare 403.
fetch() {
  local url="$1" out="$2" final
  if ! final=$(curl -fsSL -o "$out" -w '%{url_effective}' "$url"); then
    final=$(curl -sIL -o /dev/null -w '%{url_effective}' "$url" || true)
    echo "download failed: $url" >&2
    echo "  final host: $(echo "${final:-$url}" | awk -F/ '{print $3}') - add it to the environment's allowed domains" >&2
    return 1
  fi
}

# The base image already has what OTP needs (curl, libssl, libncurses). apt is
# only a fallback: the Custom network setting usually blocks the Ubuntu
# archive, and a failed `apt-get update` must not end the script.
#
# inotify-tools is the exception the harness needs: its file watcher shells out
# to inotifywait on Linux, and without it the watcher fails to start and takes
# the project channel down with it, so the harness rejoins about once a second.
# Allow archive.ubuntu.com and security.ubuntu.com for this to install.
missing=""
command -v curl >/dev/null || missing="$missing curl ca-certificates"
command -v inotifywait >/dev/null || missing="$missing inotify-tools"
if [ -n "$missing" ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1 || true
  # shellcheck disable=SC2086
  apt-get install -y -qq $missing >/dev/null 2>&1 || true
fi
command -v inotifywait >/dev/null \
  || echo "WARN: no inotifywait; the harness channel will crash-loop. Allow the Ubuntu archive hosts." >&2

if [ ! -x /opt/otp/bin/erl ]; then
  # Install fixes paths up in place: its root must be the unpacked directory.
  mkdir -p /opt/otp
  fetch "https://builds.hex.pm/builds/otp/ubuntu-24.04/OTP-${OTP_VERSION}.tar.gz" /tmp/otp.tar.gz
  tar xzf /tmp/otp.tar.gz -C /opt/otp --strip-components=1
  (cd /opt/otp && ./Install -minimal /opt/otp >/dev/null)
fi

if [ ! -x /opt/elixir/bin/elixir ]; then
  fetch "https://builds.hex.pm/builds/elixir/v${ELIXIR_VERSION}-otp-28.zip" /tmp/elixir.zip
  mkdir -p /opt/elixir
  if command -v unzip >/dev/null; then
    unzip -qo /tmp/elixir.zip -d /opt/elixir
  else
    python3 -c 'import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' \
      /tmp/elixir.zip /opt/elixir
  fi
  # zipfile drops the executable bit.
  chmod +x /opt/elixir/bin/*
fi

# Symlinks, not a profile.d PATH: hooks and the harness inherit Claude's
# environment, which no login profile touches.
for b in /opt/otp/bin/* /opt/elixir/bin/*; do ln -sf "$b" /usr/local/bin/; done

# sops only decrypts envs/test.env for the analyzers, so a blocked download
# warns instead of failing the whole setup. GitHub serves release files from
# release-assets.githubusercontent.com.
if [ ! -x /usr/local/bin/sops ]; then
  if fetch "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.amd64" /tmp/sops; then
    install -m 755 /tmp/sops /usr/local/bin/sops
  else
    echo "WARN: no sops; the analyzers will not have envs/test.env" >&2
  fi
fi

# Shared, world-writable Mix/Hex homes so whichever user Claude runs as finds
# hex and rebar already installed.
mkdir -p /opt/mix /opt/hex && chmod 777 /opt/mix /opt/hex
MIX_HOME=/opt/mix HEX_HOME=/opt/hex mix local.hex --force >/dev/null
MIX_HOME=/opt/mix HEX_HOME=/opt/hex mix local.rebar --force >/dev/null

# config/test.exs connects as postgres/postgres on localhost.
service postgresql start >/dev/null 2>&1 || true
su postgres -c "psql -qc \"ALTER USER postgres PASSWORD 'postgres'\"" >/dev/null 2>&1 || true

cat > /usr/local/bin/cms-cloud-session <<'SESSION'
#!/usr/bin/env bash
# SessionStart hook: onboard this checkout and start its harness, detached, so
# the session is never held up (the first boot compiles for minutes). Always
# exits 0; read ~/.codemyspec/cloud-session.log for what happened.
cat >/dev/null
[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0

export MIX_HOME=/opt/mix HEX_HOME=/opt/hex
export PATH="/usr/local/bin:$PATH"
# The container sends crates.io around its egress proxy, where it is refused
# (403); through the proxy it is allowed. Drop it from the bypass list so the
# Rust NIFs can fetch their crates.
for v in NO_PROXY no_proxy; do
  [ -n "${!v:-}" ] && export "$v=$(echo "${!v}" | tr , '\n' | grep -v crates.io | paste -sd, -)"
done
port="${CMS_HARNESS_PORT:-4004}"
export CMS_HARNESS_PORT="$port"
root="${CLAUDE_PROJECT_DIR:-$PWD}"
# The source entry resolves the server from CMS_SERVER_URL, the existing
# harness record, or .code_my_spec/config.yml. Do not guess a remote target.
mkdir -p "$HOME/.codemyspec"
log="$HOME/.codemyspec/cloud-session.log"

setsid bash -c '
  root="$1"; port="$2"; log="$3"
  echo "== $(date -u +%FT%TZ) session start in $root"

  if curl -fs "localhost:$port/health" >/dev/null; then
    echo "harness already up"
    exit 0
  fi

  (sudo -n service postgresql start || service postgresql start) >/dev/null 2>&1 || true

  cd "$root" || exit 0
  export CMS_PROJECT_DIR="$root"
  git submodule update --init || echo "WARN: .code_my_spec submodule did not initialise"

  # The shared source entry installs missing prerequisites, asks for device
  # approval when needed, onboards this copy, then starts the harness.
  CMS_PROJECT_DIR="$root" CMS_HARNESS_PORT=$port \
    nohup bash scripts/start-harness >>"$HOME/.codemyspec/harness.out" 2>&1 &
  echo "harness onboarding/starting (pid $!); approve the code in ~/.codemyspec/harness.out"

  # Once the harness has joined it installs the project age keys, and then the
  # test env can be decrypted for the analyzers. Waits in the background.
  (
    umask 077
    keyring="$HOME/.config/sops/age/keys.txt"
    for _ in $(seq 1 120); do
      [ -s "$keyring" ] && break
      sleep 10
    done
    if [ ! -s "$keyring" ]; then
      echo "ERROR: timed out waiting for the project age keyring at $keyring; the harness must join and install the project keys before dev/test decryption can proceed" >&2
      exit 1
    fi

    for e in dev test; do
      temporary=$(mktemp "envs/.$e.env.XXXXXX") || {
        echo "ERROR: cannot create temporary output for envs/$e.env; decryption stopped" >&2
        exit 1
      }
      if ! sops -d --input-type dotenv --output-type dotenv \
          "envs/$e.enc.env" > "$temporary" 2>/dev/null; then
        rm -f -- "$temporary"
        echo "ERROR: cannot decrypt envs/$e.enc.env; the required project age key may be missing from $keyring or unusable. The harness installs project keys when it serves the project; decryption stopped" >&2
        exit 1
      fi
      if ! mv -f -- "$temporary" "envs/$e.env"; then
        rm -f -- "$temporary"
        echo "ERROR: cannot install envs/$e.env; decryption stopped" >&2
        exit 1
      fi
      echo "envs/$e.env decrypted"
    done
  ) &
' _ "$root" "$port" "$log" </dev/null >>"$log" 2>&1 &
exit 0
SESSION
bash -n /usr/local/bin/cms-cloud-session
chmod +x /usr/local/bin/cms-cloud-session

# The published plugin: hooks and MCP on localhost:4004. Installed for every
# home that might run Claude, best effort.
if command -v claude >/dev/null; then
  claude plugin marketplace add Code-My-Spec/plugins >/dev/null 2>&1 || true
  claude plugin install codemyspec@codemyspec >/dev/null 2>&1 \
    || echo "WARN: could not install the codemyspec plugin from the setup script"
fi

# User-level SessionStart hook that starts the harness. Merged into any existing
# settings rather than overwriting them.
for cloud_user_home in /root /home/*; do
  [ -d "$cloud_user_home" ] || continue
  mkdir -p "$cloud_user_home/.claude"
  settings="$cloud_user_home/.claude/settings.json"
  [ -f "$settings" ] || echo '{}' > "$settings"
  node -e '
    const fs = require("fs"), f = process.argv[1];
    const s = JSON.parse(fs.readFileSync(f, "utf8"));
    s.env = Object.assign({}, s.env, {CMS_HARNESS_PORT: process.env.CMS_HARNESS_PORT || "4004"});
    const hook = {hooks: [{type: "command", command: "/usr/local/bin/cms-cloud-session", timeout: 600}]};
    s.hooks = s.hooks || {};
    const list = (s.hooks.SessionStart = s.hooks.SessionStart || []);
    if (!JSON.stringify(list).includes("cms-cloud-session")) list.push(hook);
    s.enabledPlugins = Object.assign({}, s.enabledPlugins, {"codemyspec@codemyspec": true});
    s.extraKnownMarketplaces = Object.assign({}, s.extraKnownMarketplaces, {
      codemyspec: {source: {source: "github", repo: "Code-My-Spec/plugins"}}
    });
    fs.writeFileSync(f, JSON.stringify(s, null, 2));
  ' "$settings"
  chown -R "$(stat -c %U "$cloud_user_home")" "$cloud_user_home/.claude" 2>/dev/null || true
done

echo "cms cloud setup done: $(elixir --version | tail -1)"
