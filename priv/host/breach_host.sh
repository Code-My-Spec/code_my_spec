#!/usr/bin/env bash
#
# Prove the host-level isolation checks catch a real breach.
#
#   breach_host.sh <app> <other>
#
# verify_isolation.sh passing on a correctly-hardened box tells you nothing
# unless you have also seen each check FAIL on a broken one — every one of them
# defaults to open, so a check that never fires looks identical to isolation
# working. drill.sh does this for the three per-app checks (key, database,
# distribution) in the stubbed image. This does it for the three the shared
# host owns, and needs the real thing: running apps, real Caddy, a real /proc.
#
# The routing breach is the odd one out: it is the only *positive* claim in the
# set — that Caddy serves this app's hostname from this app. It is here because
# getting it wrong is a tenant boundary failure that every other check misses,
# both apps being perfectly healthy while the wrong one answers.
# Run it against the container up.sh brings up, or on the box itself:
#
#   docker exec cms-host-run /host/breach_host.sh app1 app2
#
# Each breach is undone immediately after it is caught, and the script ends by
# re-asserting a fully green board — a breach test that left the box broken
# would be its own worst finding.

set -uo pipefail

APP="${1:?usage: breach_host.sh <app> <other>}"
OTHER="${2:?usage: breach_host.sh <app> <other>}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY="$HERE/verify_isolation.sh"
APP_PORT_RANGE="${APP_PORT_RANGE:-4000:4999}"

fails=0

# Assert that a breach makes verify_isolation report a FAIL line matching a
# pattern. A breach that the check does NOT catch is the failure this script
# exists to surface.
expect_caught() {
  local label="$1" pattern="$2" out
  # Capture rather than pipe: a caught breach makes verify_isolation exit
  # non-zero, and with `pipefail` that non-zero would mask grep's success and
  # read every caught breach as missed. `|| true` keeps that expected non-zero
  # from tripping the caller.
  out="$("$VERIFY" "$APP" "$OTHER" 2>&1 || true)"
  if grep -qE "FAIL.*$pattern" <<<"$out"; then
    printf '  \033[32mCAUGHT\033[0m %s\n' "$label"
  else
    printf '  \033[31mMISSED\033[0m %s — the check did not fire on a breached box\n' "$label"
    fails=$((fails + 1))
  fi
}

echo "breach test: each host-level check must catch its breach"
echo

# ---------------------------------------------------- 1. /proc hidepid
echo "### breach: /proc mounted without hidepid (argv cookie visible)"
mount -o remount,hidepid=0 /proc
expect_caught "cookie via /proc argv" "distribution cookie via /proc"
mount -o remount,hidepid=2 /proc

# --------------------------------------------------- 2. Caddy admin API
echo "### breach: Caddy admin API back on TCP 127.0.0.1:2019"
printf '{\n\tadmin 127.0.0.1:2019\n}\n\nimport /etc/caddy/sites/*.caddy\n' > /etc/caddy/Caddyfile
systemctl restart caddy
# Give caddy a moment to open the port before probing.
for _ in 1 2 3 4 5; do curl -s -o /dev/null -m 1 http://127.0.0.1:2019/ && break; sleep 1; done
expect_caught "Caddy admin API reachable" "Caddy admin API"
printf '{\n\tadmin unix//run/caddy/admin.sock\n}\n\nimport /etc/caddy/sites/*.caddy\n' > /etc/caddy/Caddyfile
systemctl restart caddy

# ------------------------------------------------- 3. app-port firewall
echo "### breach: app-port firewall reject rule removed"
iptables -D OUTPUT -o lo -p tcp --dport "$APP_PORT_RANGE" -j REJECT --reject-with tcp-reset 2>/dev/null || true
expect_caught "cross-tenant app port reachable" "app port"
"$HERE/harden_host.sh" >/dev/null 2>&1

# ------------------------------------------------ 4. Caddy routes the host
echo "### breach: $APP's hostname pointed at $OTHER's upstream"
other_port="$(sed -n 's/^Environment=PORT=//p' "/etc/systemd/system/$OTHER.service" 2>/dev/null | head -1)"
app_port="$(sed -n 's/^Environment=PORT=//p' "/etc/systemd/system/$APP.service" 2>/dev/null | head -1)"
sed -i "s/localhost:$app_port/localhost:$other_port/" "/etc/caddy/sites/$APP.caddy"
systemctl reload caddy
sleep 2
expect_caught "hostname served by the wrong app" "routing this host to the wrong app"
sed -i "s/localhost:$other_port/localhost:$app_port/" "/etc/caddy/sites/$APP.caddy"
systemctl reload caddy
sleep 2

echo
echo "### restored — the board must be green again"
if "$VERIFY" "$APP" "$OTHER"; then
  echo
  if [[ "$fails" -eq 0 ]]; then
    echo "all host-level checks caught their breach and the box is green"
  else
    echo "$fails check(s) did not catch a breach — see MISSED above"
  fi
else
  echo "restore FAILED — the box is left breached, fix before relying on it" >&2
  fails=$((fails + 1))
fi

[[ "$fails" -eq 0 ]]
