#!/usr/bin/env bash
# Bring up a full host in Docker: systemd, Postgres, Caddy, two running apps.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="${1:-cms-host-run}"

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw -p 8080:80 cms-host >/dev/null

until docker exec "$NAME" systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded'; do sleep 1; done

# Host-wide hardening before any app starts: /proc hidepid, the app-port
# firewall, and the Caddy admin-socket dir. These close the three cross-tenant
# leaks a pen test found; verify_isolation.sh asserts they stay closed.
docker exec "$NAME" /host/harden_host.sh

docker exec "$NAME" bash -c '
set -e
export ADMIN_AGE_PUBKEY=$(age-keygen 2>/dev/null | grep "public key" | sed "s/.*: //")
for a in app1 app2; do
  p=$([ "$a" = app1 ] && echo 4001 || echo 4002)
  /host/provision_app.sh "$a" "$p" "$a.localhost" >/dev/null

  # Copy the release *contents* in. `cp -a src/. dst/` copies the source
  # directory metadata onto dst — including its 755 mode — which silently
  # widens /opt/$a from the 750 provisioning set. The real tarball deploy has
  # the same trap, so /opt/$a is re-asserted 750 after any release lands.
  cp -aT /srv/releases/$a /opt/$a
  chown -R "$a:$a" /opt/$a
  chmod 750 /opt/$a

  # The release ships releases/COOKIE at 0644 — world-readable. Distribution
  # is off (RELEASE_DISTRIBUTION=none) so the cookie is inert today, but a pen
  # test showed any user on the box can read it, and the isolation rests
  # entirely on distribution staying off. 640 costs nothing and closes one of
  # the three leak paths. (The argv leak needs hidepid; noted in the README.)
  find /opt/$a -name COOKIE -exec chmod 640 {} +

  systemctl start "$a"
done
sleep 6
systemctl is-active app1 app2
'
echo "host up as $NAME"
