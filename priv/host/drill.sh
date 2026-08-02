#!/usr/bin/env bash
#
# Rehearse the host build in Docker, then try to break it.
#
#   ./drill.sh
#
# Provisions two apps and runs the isolation checks — then deliberately
# breaches each one and confirms the check catches it. The second half is the
# point: three checks that pass on a correctly built box tell you nothing
# unless you have also seen them fail on a broken one. All three of these
# default to *open*, so a check that silently never fires looks exactly like
# isolation working.
#
# systemd and Caddy are stubbed in the container. The unit file and site block
# are written and diffed, but not started — running systemd in a container
# proves something about the container, not about the host.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE=cms-host-drill

echo "building drill image"
docker build -q -f "$HERE/Dockerfile.drill" -t "$IMAGE" "$HERE" >/dev/null

docker run --rm "$IMAGE" bash -c '
set -euo pipefail

service postgresql start >/dev/null 2>&1
until su - postgres -c "psql -tAc \"select 1\"" >/dev/null 2>&1; do sleep 1; done

export ADMIN_AGE_PUBKEY=$(age-keygen 2>/dev/null | grep "public key" | sed "s/.*: //")

echo "### provision"
./provision_app.sh app1 4001 >/dev/null
./provision_app.sh app2 4002 >/dev/null

# Re-run one of them: idempotence is a property worth checking every drill,
# because the run most likely to fail partway is the first one.
./provision_app.sh app1 4001 >/dev/null
echo "  two apps provisioned, re-run clean"

echo
echo "### the unit that would run"
sed -n "/ExecStart/p;/RELEASE_DISTRIBUTION/p;/ProtectSystem/p" /etc/systemd/system/app1.service | sed "s/^/  /"

echo
echo "### isolation, as built"
./verify_isolation.sh app1 app2

echo
echo "### breach 1: app2 key world-readable"
chmod 444 /etc/app2/age.key
./verify_isolation.sh app1 app2 | grep -E "age.key" | sed "s/^/  /" || true
chmod 400 /etc/app2/age.key

echo
echo "### breach 2: CONNECT back to PUBLIC (Postgres default)"
su - postgres -c "psql -q -d app2 -c \"GRANT CONNECT ON DATABASE app2 TO PUBLIC;\"" >/dev/null
./verify_isolation.sh app1 app2 | grep -E "database app2" | sed "s/^/  /" || true
su - postgres -c "psql -q -d app2 -c \"REVOKE CONNECT ON DATABASE app2 FROM PUBLIC;\"" >/dev/null

echo
echo "### breach 3: app2 joins BEAM distribution"
su -s /bin/bash app2 -c "erl -noshell -sname app2 -setcookie shared -eval \"timer:sleep(30000).\" &" >/dev/null 2>&1
sleep 3
./verify_isolation.sh app1 app2 | grep -E "epmd" | sed "s/^/  /" || true

echo
echo "drill complete — each breach above must read FAIL"
'
