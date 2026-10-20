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
#   CMS_SERVER_URL   __SERVER_URL__
# The box token is NOT an environment variable: environment variables are readable
# by anyone using the environment. Add it as a network secret for __SERVER_HOST__.
set -euo pipefail

OTP_VERSION=28.1
ELIXIR_VERSION=1.19.4
SOPS_VERSION=3.10.2

# The base image already has what OTP needs (curl, libssl, libncurses). apt is
# only a fallback: the Custom network setting usually blocks the Ubuntu
# archive, and a failed `apt-get update` must not end the script.
if ! command -v curl >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y -qq curl ca-certificates >/dev/null 2>&1 || true
fi

if [ ! -x /opt/otp/bin/erl ]; then
  # Install fixes paths up in place: its root must be the unpacked directory.
  mkdir -p /opt/otp
  curl -fsSL "https://builds.hex.pm/builds/otp/ubuntu-24.04/OTP-${OTP_VERSION}.tar.gz" \
    | tar xz -C /opt/otp --strip-components=1
  (cd /opt/otp && ./Install -minimal /opt/otp >/dev/null)
fi

if [ ! -x /opt/elixir/bin/elixir ]; then
  curl -fsSL -o /tmp/elixir.zip "https://builds.hex.pm/builds/elixir/v${ELIXIR_VERSION}-otp-28.zip"
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

if [ ! -x /usr/local/bin/sops ]; then
  curl -fsSL -o /usr/local/bin/sops \
    "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.amd64"
  chmod +x /usr/local/bin/sops
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
port=4003
root="${CLAUDE_PROJECT_DIR:-$PWD}"
server="${CMS_SERVER_URL:-__SERVER_URL__}"
mkdir -p "$HOME/.codemyspec"
log="$HOME/.codemyspec/cloud-session.log"

setsid bash -c '
  root="$1"; port="$2"; server="$3"; log="$4"
  echo "== $(date -u +%FT%TZ) session start in $root (server $server)"
  if curl -fs "localhost:$port/health" >/dev/null; then
    echo "harness already up"
    exit 0
  fi
  (sudo -n service postgresql start || service postgresql start) >/dev/null 2>&1 || true
  cd "$root" || exit 0
  git submodule update --init || echo "WARN: .code_my_spec submodule did not initialise"
  MIX_ENV=harness mix deps.get >/dev/null
  if [ ! -f .cms_harness.json ]; then
    MIX_ENV=harness mix cms.harness.onboard "$root" --server-url "$server" --device cloud \
      || { echo "ERROR: onboard failed"; exit 0; }
  fi
  # Backgrounded and detached: the first boot compiles, which takes minutes.
  CMS_HARNESS=1 CMS_DEV_BOX=1 CMS_HARNESS_PORT=$port CMS_SERVER_URL="$server" CMS_ANALYSIS_SLOTS=1 \
    MIX_ENV=harness nohup elixir -S mix run --no-halt >>"$HOME/.codemyspec/harness.out" 2>&1 &
  echo "harness starting (pid $!); boot output in ~/.codemyspec/harness.out"
  # Once the harness has joined it installs the project age keys, and then the
  # test env can be decrypted for the analyzers. Waits in the background.
  (
    for _ in $(seq 1 120); do
      if [ -s "$HOME/.config/sops/age/keys.txt" ]; then
        for e in dev test; do
          (umask 077 && sops -d --input-type dotenv --output-type dotenv \
            "envs/$e.enc.env" > "envs/$e.env") && echo "envs/$e.env decrypted"
        done
        break
      fi
      sleep 10
    done
  ) &
' _ "$root" "$port" "$server" "$log" </dev/null >>"$log" 2>&1 &
exit 0
SESSION
chmod +x /usr/local/bin/cms-cloud-session

# The published plugin: hooks and MCP on localhost:4003. Installed for every
# home that might run Claude, best effort.
if command -v claude >/dev/null; then
  claude plugin marketplace add Code-My-Spec/plugins >/dev/null 2>&1 || true
  claude plugin install codemyspec@codemyspec >/dev/null 2>&1 \
    || echo "WARN: could not install the codemyspec plugin from the setup script"
fi

# User-level SessionStart hook that starts the harness. Merged into any existing
# settings rather than overwriting them.
for home in /root /home/*; do
  [ -d "$home" ] || continue
  mkdir -p "$home/.claude"
  settings="$home/.claude/settings.json"
  [ -f "$settings" ] || echo '{}' > "$settings"
  node -e '
    const fs = require("fs"), f = process.argv[1];
    const s = JSON.parse(fs.readFileSync(f, "utf8"));
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
  chown -R "$(stat -c %U "$home")" "$home/.claude" 2>/dev/null || true
done

echo "cms cloud setup done: $(elixir --version | tail -1)"
