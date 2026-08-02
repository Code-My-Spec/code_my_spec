#!/usr/bin/env bash
#
# Prove one app cannot reach another.
#
#   verify_isolation.sh <app> <other>
#
# This is the acceptance criterion for the shared host, not a nice-to-have.
# The build is incomplete until all three checks fail as expected, because
# every one of them defaults to *open*:
#
#   - Postgres grants CONNECT to PUBLIC on new databases
#   - a readable key file is readable by anyone who can traverse to it
#   - all apps share one epmd, and a known cookie is remote code execution
#
# Each check asserts a *failure*. A check that errors for the wrong reason —
# psql missing, app not provisioned — would look identical to isolation
# working, so each one confirms the positive case first: `app` really can read
# its own key, and really can reach its own database. Without that, this script
# passes on a box where nothing is installed.

set -uo pipefail

APP="${1:?usage: verify_isolation.sh <app> <other>}"
OTHER="${2:?usage: verify_isolation.sh <app> <other>}"

pass=0
fail=0

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail + 1)); }
note() { printf '       %s\n' "$*"; }

as_app() { su -s /bin/bash "$APP" -c "$1"; }

echo "isolation: $APP must not reach $OTHER"
echo

# ------------------------------------------------- control: the positive case
# Without these, every check below could pass because nothing works at all.
if as_app "test -r /etc/$APP/age.key" 2>/dev/null; then
  ok "$APP can read its own age key (control)"
else
  bad "$APP cannot read its OWN age key — the checks below prove nothing"
  note "provision $APP before running this"
  exit 1
fi

if as_app "psql -d $APP -tAc 'select 1'" >/dev/null 2>&1; then
  ok "$APP can reach its own database (control)"
else
  bad "$APP cannot reach its OWN database — the checks below prove nothing"
  exit 1
fi

echo

# ----------------------------------------------------------- 1. the key file
if as_app "cat /etc/$OTHER/age.key" >/dev/null 2>&1; then
  bad "$APP READ $OTHER's age key"
  note "expected mode 400 owned by $OTHER:$OTHER — check /etc/$OTHER/age.key"
else
  ok "$APP cannot read /etc/$OTHER/age.key"
fi

# ------------------------------------------------- 1b. the home directory
# A pen test found /opt/$OTHER at 755 rather than 750, which let $APP list the
# other app's release layout and read every world-readable file in it. No
# secret leaked — but recon is the first move, and the fix (750) costs
# nothing. A `cp -a release/. /opt/app/` deploy silently widens this, so it is
# worth checking every time rather than trusting it was set once.
if as_app "ls /etc/../opt/$OTHER/" >/dev/null 2>&1; then
  bad "$APP can list /opt/$OTHER — its home is world-traversable"
  note "run: chmod 750 /opt/$OTHER  (a release copy resets this to 755)"
else
  ok "$APP cannot list /opt/$OTHER"
fi

# ---------------------------------------------------------- 2. the database
# `-tAc` so a successful connect produces output we can distinguish from an
# error; the connection succeeding at all is the failure.
if as_app "psql -d $OTHER -tAc 'select 1'" >/dev/null 2>&1; then
  bad "$APP CONNECTED to database $OTHER"
  note "run: REVOKE CONNECT ON DATABASE \"$OTHER\" FROM PUBLIC;"
  note "Postgres grants CONNECT to PUBLIC by default — this is the step people skip"
else
  ok "$APP cannot connect to database $OTHER"
fi

# ------------------------------------------------------ 3. BEAM distribution
# The highest-severity one. If $OTHER is registered with epmd and its cookie
# leaks, any node that knows it gets :erpc — arbitrary code execution as
# $OTHER. The intended posture is RELEASE_DISTRIBUTION=none, so $OTHER should
# not appear in epmd at all.
if ! command -v epmd >/dev/null 2>&1; then
  note "epmd not installed — skipping distribution check"
else
  names="$(epmd -names 2>/dev/null || true)"

  if grep -qi "name $OTHER " <<<"$names"; then
    bad "$OTHER is registered with epmd — it is reachable over distribution"
    note "set RELEASE_DISTRIBUTION=none in rel/env.sh.eex unless it must cluster"
    note "if it must cluster, give it a cookie no other app on this box knows"
  else
    ok "$OTHER is not registered with epmd (distribution off)"
  fi

  # Belt and braces: even with a node up, a wrong cookie must not connect.
  # Skipped when there is nothing to probe, rather than reported as a pass.
  if grep -qi "name $OTHER " <<<"$names" && command -v erl >/dev/null 2>&1; then
    probe="$(as_app "erl -noshell -sname isolation_probe$$ -setcookie definitely-not-the-cookie \
      -eval 'io:format(\"~p\", [net_adm:ping('\"'\"'$OTHER@localhost'\"'\"')]), halt().'" 2>/dev/null || echo pang)"

    if [[ "$probe" == "pong" ]]; then
      bad "$APP reached $OTHER's node over distribution with a wrong cookie"
    else
      ok "$APP cannot reach $OTHER's node (ping: ${probe:-pang})"
    fi
  fi
fi

# ------------------------------------------ 4. the cookie via /proc argv
# The distribution check above assumes the cookie stays confidential. It does
# not by default: a release boots with `-setcookie <value>` on its command
# line, so the cookie sits in /proc/<pid>/cmdline, world-readable. A pen test
# read $OTHER's cookie this way as $APP — defeating the locked-down COOKIE
# file. hidepid=2 (harden_host.sh) hides other users' /proc entries, so $APP
# cannot find $OTHER's pid, let alone its argv. Skipped when $OTHER is not
# running, rather than reported as a pass.
other_pid="$(pgrep -u "$OTHER" beam.smp 2>/dev/null | head -1 || true)"
if [[ -z "$other_pid" ]]; then
  note "no running $OTHER beam — cookie-via-/proc check skipped"
elif as_app "tr '\\0' ' ' < /proc/$other_pid/cmdline" 2>/dev/null | grep -q -- '-setcookie'; then
  bad "$APP read $OTHER's distribution cookie via /proc/$other_pid/cmdline"
  note "mount /proc with hidepid=2 (harden_host.sh) so tenants cannot read each other's argv"
else
  ok "$APP cannot read $OTHER's process argv (/proc hidepid)"
fi

# ------------------------------------------------- 5. the Caddy admin API
# Caddy's admin API is the ingress control plane: whoever reaches it reads and
# rewrites every app's routing. A pen test reached it as $APP on its default
# TCP port (127.0.0.1:2019) and could have hijacked or downed all tenants'
# sites. It must be reachable by neither the TCP port nor the unix socket.
# curl exiting 0 means the connection was accepted at all — which is the
# failure here, regardless of the HTTP status it then returns.
if as_app "curl -s -m 3 -o /dev/null http://127.0.0.1:2019/config/" 2>/dev/null; then
  bad "$APP reached the Caddy admin API on 127.0.0.1:2019"
  note "move admin off TCP: 'admin unix//run/caddy/admin.sock' in a 0750 caddy dir"
elif [[ -S /run/caddy/admin.sock ]] && \
     as_app "curl -s -m 3 --unix-socket /run/caddy/admin.sock -o /dev/null http://localhost/config/" 2>/dev/null; then
  bad "$APP reached the Caddy admin API via /run/caddy/admin.sock"
  note "the socket's dir must be 0750 caddy:caddy so tenants cannot traverse to it"
else
  ok "$APP cannot reach the Caddy admin API"
fi

# --------------------------------------------- 6. the other app's HTTP port
# App ports listen on localhost for Caddy to proxy to — but localhost is not a
# boundary between tenants on one box. A pen test hit $OTHER's Phoenix port
# directly as $APP, bypassing Caddy's TLS, host routing and any edge policy.
# The owner-matched firewall (harden_host.sh) lets only root and caddy connect.
# Read $OTHER's port from its unit; skip if it is not actually listening.
other_port="$(sed -n 's/^Environment=PORT=//p' "/etc/systemd/system/$OTHER.service" 2>/dev/null | head -1 || true)"
if [[ -z "$other_port" ]] || ! curl -s -m 3 -o /dev/null "http://127.0.0.1:$other_port/" 2>/dev/null; then
  note "$OTHER's app port not reachable even as root — port-reach check skipped"
elif as_app "curl -s -m 3 -o /dev/null http://127.0.0.1:$other_port/" 2>/dev/null; then
  bad "$APP reached $OTHER's app port :$other_port directly, bypassing Caddy"
  note "run harden_host.sh: only root+caddy may open app ports on loopback"
else
  ok "$APP cannot reach $OTHER's app port :$other_port (Caddy is the only path)"
fi

echo
echo "$pass passed, $fail failed"

# Non-zero on any failure so this can gate a deploy rather than being read by
# a human who may or may not be looking.
[[ "$fail" -eq 0 ]]
