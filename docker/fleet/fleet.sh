#!/usr/bin/env bash
# Bring the local fleet up and down.
#
# The key is generated here rather than committed. It grants root on the boxes,
# and a keypair in a public repository is a keypair on every machine that ever
# clones it — worthless as a secret, but still a working credential against
# anyone who runs this fleet on something reachable.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
compose=(docker-compose -f "$here/docker-compose.yml")
key="$here/keys/fleet"

ensure_key() {
  mkdir -p "$here/keys"
  if [ ! -f "$key" ]; then
    ssh-keygen -t ed25519 -N "" -C "cms-fleet" -f "$key" >/dev/null
    echo "fleet: generated $key"
  fi
  cp "$key.pub" "$here/keys/authorized_keys"
}

case "${1:-up}" in
  up)
    ensure_key
    shift || true
    "${compose[@]}" up -d --wait "$@"
    echo
    echo "fleet up:"
    echo "  builder   ssh -i $key -p 2222 root@127.0.0.1"
    echo "  app       ssh -i $key -p 2223 root@127.0.0.1   (app on :8080)"
    echo "  registry  http://127.0.0.1:5010/v2/"
    echo "  minio     http://127.0.0.1:9000   console :9001   cms-fleet / cms-fleet-secret"
    echo "  postgres  postgres://app:app@127.0.0.1:5433/app_uat"
    ;;

  # `-v` is the default, not a flag. A fleet that keeps its volumes remembers
  # the last run, and a test that passes on yesterday's bucket or yesterday's
  # image layer is the thing this exists to stop.
  down)
    shift || true
    "${compose[@]}" down -v "$@"
    ;;

  # Everything else goes straight through, so `fleet.sh ps`, `fleet.sh logs -f
  # builder` and friends work without wrapping each one.
  *)
    "${compose[@]}" "$@"
    ;;
esac
