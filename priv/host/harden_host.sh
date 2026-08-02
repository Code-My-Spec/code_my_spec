#!/usr/bin/env bash
#
# Host-wide hardening, applied once per box. Idempotent — safe to re-run, and
# a re-run is how a drifted setting gets corrected.
#
#   harden_host.sh
#
# provision_app.sh sets up one app; this sets up the box everything shares.
# Three tenant-boundary leaks a pen test found have no per-app fix, because the
# thing that leaks is shared: /proc, the loopback interface, and Caddy's admin
# API. Each one below closes a verified cross-tenant reach — the same ones
# verify_isolation.sh now asserts stay closed.

set -euo pipefail

# The port band apps are assigned from. Kept in sync with the ports handed to
# provision_app.sh; anything a tenant could bind for its own service lives
# outside it.
APP_PORT_RANGE="${APP_PORT_RANGE:-4000:4999}"

log() { printf '  %s\n' "$*"; }

echo "hardening host"

# ------------------------------------------------------- 1. /proc hidepid
#
# A Mix release's boot passes `-setcookie <value>` on the beam command line, so
# the cookie sits in /proc/<pid>/cmdline — world-readable by default. That
# defeats the locked-down releases/COOKIE file: any tenant reads any other
# tenant's cookie straight out of /proc. The cookie is inert only while
# RELEASE_DISTRIBUTION=none holds on every app; the day one clusters, a leaked
# cookie is `:erpc` — arbitrary code execution as that user. hidepid=2 hides
# other users' process entries entirely, so the argv never leaks in the first
# place. root still sees everything; each tenant sees only its own processes.
if mount | grep -qE 'on /proc .*\bhidepid='; then
  log "/proc already mounted hidepid"
else
  mount -o remount,hidepid=2 /proc
  log "remounted /proc hidepid=2"
fi
# Persist across reboots. On the real box iptables-persistent / systemd remount
# this at boot; the fstab line is what makes hidepid survive one.
if ! grep -qE '^proc[[:space:]]+/proc.*hidepid' /etc/fstab 2>/dev/null; then
  echo 'proc /proc proc defaults,hidepid=2 0 0' >> /etc/fstab
  log "recorded hidepid in /etc/fstab"
fi

# --------------------------------------------------- 2. app-port firewall
#
# App HTTP ports listen on localhost so Caddy can proxy to them. But localhost
# is not a trust boundary when untrusted tenant code runs on the box: a pen
# test hit app2's Phoenix port directly as app1, bypassing everything Caddy
# enforces at the edge (TLS, host routing, any future auth/rate limit). Only
# root and caddy have a reason to open these ports; a tenant never does. An
# owner-matched reject on OUTPUT closes the whole band at once. A dedicated
# chain makes the rule idempotent — re-running flushes and rebuilds it rather
# than stacking duplicates.
if command -v iptables >/dev/null 2>&1; then
  CADDY_UID="$(id -u caddy)"
  # Append straight to OUTPUT rather than a user-defined chain: the nf_tables
  # backend rejects the `owner` match inside a custom chain. `-C` before `-A`
  # makes each rule idempotent; the two ACCEPTs precede the REJECT because they
  # are added together, in order, on the first run.
  add_rule() { iptables -C "$@" 2>/dev/null || iptables -A "$@"; }
  add_rule OUTPUT -o lo -p tcp --dport "$APP_PORT_RANGE" -m owner --uid-owner 0 -j ACCEPT
  add_rule OUTPUT -o lo -p tcp --dport "$APP_PORT_RANGE" -m owner --uid-owner "$CADDY_UID" -j ACCEPT
  add_rule OUTPUT -o lo -p tcp --dport "$APP_PORT_RANGE" -j REJECT --reject-with tcp-reset
  log "app-port firewall ($APP_PORT_RANGE): only root+caddy may connect"
  # Best effort — on a real box iptables-persistent saves this for reboot.
  command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true
else
  log "iptables absent — app-port firewall skipped (install iptables on the host)"
fi

# ------------------------------------------------ 3. Caddy admin socket dir
#
# The Caddyfile puts the admin API on /run/caddy/admin.sock instead of a TCP
# port. What keeps a tenant off the socket is not the socket's own mode but the
# directory's: 0750 owned by caddy means no other user can traverse to it.
# RuntimeDirectory creates /run/caddy 0755 by default, so re-assert it here.
if id caddy >/dev/null 2>&1; then
  install -d -o caddy -g caddy -m 750 /run/caddy
  log "/run/caddy is 0750 caddy:caddy"
fi

echo "host hardened"
