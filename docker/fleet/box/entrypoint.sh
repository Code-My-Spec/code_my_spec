#!/bin/sh
# Start sshd, then hand off to dind's own entrypoint so dockerd stays PID 1's
# foreground job — a box whose daemon dies should take the container with it
# rather than linger as something that answers SSH and nothing else.
set -e

if [ -f /fleet/authorized_keys ]; then
  install -m 600 /fleet/authorized_keys /root/.ssh/authorized_keys
else
  echo "fleet: no /fleet/authorized_keys mounted; nothing will be able to ssh in" >&2
fi

# Trust the fleet registry before dockerd starts, which is the one place this
# box is knowingly unlike a real one.
#
# `Registry.trust_command/1` writes exactly this file and then runs
# `systemctl restart docker`. A real box is Ubuntu and restarts; this is Alpine
# under dind, where there is no systemd and dockerd is PID 1's child, so the
# restart cannot work and the write alone would never take effect.
#
# Writing it here does not paper over that. `trust_command/1` greps for the
# host first and does nothing when it is already trusted, so the product code
# still runs and still takes a real branch — the already-trusted one. What the
# fleet genuinely cannot exercise is the write-and-restart branch, the same way
# it cannot exercise a cloud firewall. That is a limit to state, not to hide.
: "${FLEET_INSECURE_REGISTRY:=registry:5000}"
mkdir -p /etc/docker
if [ ! -f /etc/docker/daemon.json ]; then
  printf '{"insecure-registries":["%s"]}\n' "$FLEET_INSECURE_REGISTRY" > /etc/docker/daemon.json
fi

# Daemonizes itself in the background, the same way sshd above does — neither
# may hold PID 1's foreground slot, that belongs to dockerd via the exec below.
mkdir -p /etc/cron.d
/usr/sbin/crond

/usr/sbin/sshd -e

exec dockerd-entrypoint.sh "$@"
